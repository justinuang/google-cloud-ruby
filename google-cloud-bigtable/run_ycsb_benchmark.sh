#!/bin/bash
set -ex

VM_NAME=${1:-ju-ruby-sidecar-vm}
VM_ZONE=${2:-us-east1-b}

SSH_HOST="nic0.${VM_NAME}.${VM_ZONE}.c.autonomous-mote-782.internal.gcpnode.com"
SSH_USER="justinuang_google_com"
SSH_OPTS="-i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no"

echo "--- Step 1: Building and Deploying Gem ---"
cd /usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable

echo "Building gem..."
bundle exec rake sidecar:build
gem build google-cloud-bigtable.gemspec
GEM_FILE=$(ls -t google-cloud-bigtable-*.gem | head -n1)

echo "Copying scripts to VM..."
scp $SSH_OPTS $GEM_FILE ycsb_benchmark.rb $SSH_USER@$SSH_HOST:~/

echo "Uninstalling old gem and installing new gem on VM..."
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "sudo gem uninstall -aIx google-cloud-bigtable || true; sudo gem install ~/$GEM_FILE"

echo "--- Step 2: Running Benchmarks ---"
echo "Starting 3-way benchmarks in the background and waiting..."
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "bash -s" << 'EOF'
  ruby ~/ycsb_benchmark.rb --use-sidecar --app-profile-id=sidecar > ~/benchmark_sidecar.log 2>&1 &
  PID1=$!
  
  BIGTABLE_SIDECAR_DISABLE_DIRECTPATH=true ruby ~/ycsb_benchmark.rb --use-sidecar --app-profile-id=sidecarcloudpath > ~/benchmark_sidecar_cloudpath.log 2>&1 &
  PID2=$!
  
  ruby ~/ycsb_benchmark.rb --app-profile-id=nosidecar > ~/benchmark_ruby.log 2>&1 &
  PID3=$!
  
  wait -n $PID1 $PID2 $PID3
  STATUS=$?
  if [ $STATUS -ne 0 ]; then
    echo "A benchmark process failed with status $STATUS!"
    kill $PID1 $PID2 $PID3 2>/dev/null || true
    echo "--- Sidecar Logs ---"
    cat ~/benchmark_sidecar.log
    echo "--- Sidecar CloudPath Logs ---"
    cat ~/benchmark_sidecar_cloudpath.log
    echo "--- No-Sidecar Logs ---"
    cat ~/benchmark_ruby.log
    exit 1
  fi
  wait $PID1 $PID2 $PID3
EOF

if [ $? -ne 0 ]; then
  echo "Benchmarks failed early. Aborting."
  exit 1
fi

echo "--- Step 3: Fetching Results ---"
mkdir -p tmp/benchmark
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "cat ~/benchmark_sidecar.log" > tmp/benchmark/benchmark_sidecar_local.log
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "cat ~/benchmark_sidecar_cloudpath.log" > tmp/benchmark/benchmark_sidecar_cloudpath_local.log
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "cat ~/benchmark_ruby.log" > tmp/benchmark/benchmark_ruby_local.log

echo "Sidecar Results (DirectPath):"
cat tmp/benchmark/benchmark_sidecar_local.log | tail -n 20

echo ""
echo "Sidecar Results (CloudPath):"
cat tmp/benchmark/benchmark_sidecar_cloudpath_local.log | tail -n 20

echo ""
echo "Native Ruby Results:"
cat tmp/benchmark/benchmark_ruby_local.log | tail -n 20

echo "--- Step 4: Routing Verification ---"
echo "Waiting 120s for metrics to propagate to Monarch..."
sleep 120

mash --namespace=cloud_prod --deadline=600 "Query(Fetch(Raw('cloud.BigtableDataRequest', 'bigtable.googleapis.com/frontend_server/handler_latencies'), {'instance': 'ju-ruby-sidecar', 'metric:method': RegexpMatch('(google.bigtable.v2.)?Bigtable(?:\\\\.|\\\\/).*'), 'project': '450300683590'}) | Point(DistributionCount()) | Window(Rate('5m')) | GroupBy(['app_profile', 'metric:originator'], Sum()))" > tmp/benchmark/mash_routing_results.txt

echo "Routing Results:"
cat tmp/benchmark/mash_routing_results.txt
