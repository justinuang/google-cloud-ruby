#!/bin/bash
set -ex

VM_NAME=${1:-ju-ruby-sidecar-c3-vm}
VM_ZONE=${2:-us-east1-b}
DURATION=${3:-300}
PHASE=${4:-phase_18}

SSH_HOST="nic0.${VM_NAME}.${VM_ZONE}.c.autonomous-mote-782.internal.gcpnode.com"
SSH_USER="justinuang_google_com"
SSH_OPTS="-i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no"

echo "--- Step 1: Building and Deploying Gem ---"
cd "$(dirname "$0")"

echo "Building gem..."
bundle exec rake sidecar:build
gem build google-cloud-bigtable.gemspec
GEM_FILE=$(ls -t google-cloud-bigtable-*.gem | head -n1)

echo "Creating phase directory on VM..."
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "mkdir -p ~/benchmark_phases/$PHASE"

echo "Copying scripts to VM..."
scp $SSH_OPTS $GEM_FILE ycsb_benchmark.rb $SSH_USER@$SSH_HOST:~/benchmark_phases/$PHASE/

echo "Installing new gem locally on VM..."
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "gem install --no-document --install-dir ~/benchmark_phases/$PHASE/vendor ~/benchmark_phases/$PHASE/$GEM_FILE"

echo "--- Step 2: Running Benchmarks on VM ---"
echo "Starting 3-way benchmarks in the background (Duration: ${DURATION}s) and waiting..."
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "bash -s" << EOF
  cd ~/benchmark_phases/$PHASE
  export GEM_HOME=~/benchmark_phases/$PHASE/vendor
  export GEM_PATH=~/benchmark_phases/$PHASE/vendor:\$(gem env gempath)
  rm -f benchmark_sidecar.log benchmark_sidecar_cloudpath.log benchmark_ruby.log
  ruby ycsb_benchmark.rb --qps=500 --use-sidecar --app-profile-id=sidecar --duration=${DURATION} > benchmark_sidecar.log 2>&1 &
  PID1=\$!
  
  BIGTABLE_SIDECAR_DISABLE_DIRECTPATH=true ruby ycsb_benchmark.rb --qps=500 --use-sidecar --app-profile-id=sidecarcloudpath --duration=${DURATION} > benchmark_sidecar_cloudpath.log 2>&1 &
  PID2=\$!
  
  ruby ycsb_benchmark.rb --qps=500 --app-profile-id=nosidecar --duration=${DURATION} > benchmark_ruby.log 2>&1 &
  PID3=\$!
  
  wait -n \$PID1 \$PID2 \$PID3
  STATUS=\$?
  if [ \$STATUS -ne 0 ]; then
    echo "A benchmark process failed with status \$STATUS!"
    kill \$PID1 \$PID2 \$PID3 2>/dev/null || true
    echo "--- Sidecar Logs ---"
    cat benchmark_sidecar.log
    echo "--- Sidecar CloudPath Logs ---"
    cat benchmark_sidecar_cloudpath.log
    echo "--- No-Sidecar Logs ---"
    cat benchmark_ruby.log
    exit 1
  fi
  wait \$PID1 \$PID2 \$PID3
EOF

if [ $? -ne 0 ]; then
  echo "Benchmarks failed early. Aborting."
  exit 1
fi

echo "--- Step 3: Fetching Results ---"
mkdir -p tmp/$PHASE
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "cat ~/benchmark_phases/$PHASE/benchmark_sidecar.log" > tmp/$PHASE/benchmark_sidecar_local.log
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "cat ~/benchmark_phases/$PHASE/benchmark_sidecar_cloudpath.log" > tmp/$PHASE/benchmark_sidecar_cloudpath_local.log
ssh $SSH_OPTS $SSH_USER@$SSH_HOST "cat ~/benchmark_phases/$PHASE/benchmark_ruby.log" > tmp/$PHASE/benchmark_ruby_local.log

echo "Sidecar Results (DirectPath):"
cat tmp/$PHASE/benchmark_sidecar_local.log | tail -n 35

echo ""
echo "Sidecar Results (CloudPath):"
cat tmp/$PHASE/benchmark_sidecar_cloudpath_local.log | tail -n 35

echo ""
echo "Native Ruby Results:"
cat tmp/$PHASE/benchmark_ruby_local.log | tail -n 35

# echo "--- Step 4: Routing Verification ---"
# echo "Waiting 120s for metrics to propagate to Monarch..."
# sleep 120

# mash --namespace=cloud_prod --deadline=600 "Query(Fetch(Raw('cloud.BigtableDataRequest', 'bigtable.googleapis.com/frontend_server/handler_latencies'), {'instance': 'ju-ruby-sidecar', 'metric:method': RegexpMatch('(google.bigtable.v2.)?Bigtable(\\\\.|\\\\/).*'), 'project': '450300683590'}) | Point(DistributionCount()) | Window(Rate('5m')) | GroupBy(['app_profile', 'metric:originator'], Sum()))" > tmp/$PHASE/mash_routing_results.txt

# echo "Routing Results:"
# cat tmp/$PHASE/mash_routing_results.txt
