#!/bin/bash
set -ex

VM_NAME=${1:-directpath-test-vm}
VM_ZONE=${2:-us-east1-a}

echo "--- Step 1: Building and Deploying Gem ---"
cd /usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable

echo "Building gem..."
bundle exec rake sidecar:build
gem build google-cloud-bigtable.gemspec
GEM_FILE=$(ls -t google-cloud-bigtable-*.gem | head -n1)

echo "Copying scripts to VM..."
gcloud compute scp --zone=$VM_ZONE $GEM_FILE ycsb_benchmark.rb $VM_NAME:~/

echo "Uninstalling old gem and installing new gem on VM..."
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="sudo gem uninstall -aIx google-cloud-bigtable || true; sudo gem install --local ~/$GEM_FILE"

echo "--- Step 2: Running Benchmarks ---"
echo "Starting Sidecar and No-Sidecar benchmarks in the background and waiting..."
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="bash -s" << 'EOF'
  ruby ~/ycsb_benchmark.rb --use-sidecar --app-profile-id=sidecar > ~/benchmark_sidecar.log 2>&1 &
  PID1=$!
  ruby ~/ycsb_benchmark.rb --app-profile-id=nosidecar > ~/benchmark_ruby.log 2>&1 &
  PID2=$!
  
  wait -n $PID1 $PID2
  STATUS=$?
  if [ $STATUS -ne 0 ]; then
    echo "A benchmark process failed with status $STATUS!"
    kill $PID1 $PID2 2>/dev/null || true
    echo "--- Sidecar Logs ---"
    cat ~/benchmark_sidecar.log
    echo "--- No-Sidecar Logs ---"
    cat ~/benchmark_ruby.log
    exit 1
  fi
  wait $PID1 $PID2
EOF

if [ $? -ne 0 ]; then
  echo "Benchmarks failed early. Aborting."
  exit 1
fi

echo "--- Step 3: Fetching Results ---"
mkdir -p tmp/benchmark
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="cat ~/benchmark_sidecar.log" > tmp/benchmark/benchmark_sidecar_local.log
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="cat ~/benchmark_ruby.log" > tmp/benchmark/benchmark_ruby_local.log

echo "Sidecar Results:"
cat tmp/benchmark/benchmark_sidecar_local.log | tail -n 20

echo ""
echo "No-Sidecar Results:"
cat tmp/benchmark/benchmark_ruby_local.log | tail -n 20

echo "--- Step 4: Routing Verification ---"
echo "Waiting 120s for metrics to propagate to Monarch..."
sleep 120

mash --namespace=cloud_prod --deadline=600 "Query(Fetch(Raw('cloud.BigtableDataRequest', 'bigtable.googleapis.com/frontend_server/handler_latencies'), {'instance': 'ju-ruby-sidecar', 'metric:method': RegexpMatch('(google.bigtable.v2.)?Bigtable(?:\\\\.|\\\\/).*'), 'project': '450300683590'}) | Point(DistributionCount()) | Window(Rate('5m')) | GroupBy(['app_profile', 'metric:originator'], Sum()))" > tmp/benchmark/mash_routing_results.txt

echo "Routing Results:"
cat tmp/benchmark/mash_routing_results.txt
