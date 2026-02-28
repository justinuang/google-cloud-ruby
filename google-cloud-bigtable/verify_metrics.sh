#!/bin/bash
set -ex

VM_NAME=${1:-directpath-test-vm}
VM_ZONE=${2:-us-east1-a}
INSTANCE_ID=${3:-autopilot-rm-test}

echo "Using VM: $VM_NAME in zone $VM_ZONE targeting instance $INSTANCE_ID"

echo "--- Step 1: Building and Deploying Gem ---"
cd /usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable

echo "Cleaning up old gems..."
rm -f google-cloud-bigtable-*.gem

echo "Building gem..."
bundle exec rake sidecar:build
gem build google-cloud-bigtable.gemspec
GEM_FILE=$(ls -t google-cloud-bigtable-*.gem | head -n1)

echo "Copying $GEM_FILE and direct_access_flood.rb to VM..."
gcloud compute scp --zone=$VM_ZONE $GEM_FILE $VM_NAME:~/
gcloud compute scp --zone=$VM_ZONE direct_access_flood.rb $VM_NAME:~/

echo "Uninstalling old gem and installing new gem on VM..."
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="sudo gem uninstall -aIx google-cloud-bigtable || true; sudo gem install --local ~/$GEM_FILE"

echo "--- Step 2: Running Traffic Generator ---"
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="nohup ruby ~/direct_access_flood.rb > ~/directpath_flood.log 2>&1 &"

echo "--- Step 3: Verifying Version Logs ---"
# Wait a few seconds for the script to initialize and sidecar to start
sleep 5
echo "Checking VM logs for VERIFICATION_RUN_001 string..."
# We use || to handle the case where grep fails to find the string.
# If grep doesn't find the string, it exits with a non-zero code (1), which triggers the || condition.
# The { ...; exit 1; } block then prints a warning and explicitly exits the whole script with an error code (1),
# stopping the verification process immediately since the correct code isn't running.
gcloud compute ssh --zone=$VM_ZONE $VM_NAME --command="cat ~/directpath_flood.log | grep VERIFICATION_RUN_001" || { echo "WARNING: Version string not found in logs!"; exit 1; }

echo "--- Step 4: Waiting for Monarch Metrics (120 seconds) ---"
echo "Sleeping for 120 seconds to allow metrics to propagate to Monarch..."
sleep 120

echo "--- Step 5: Querying Monarch ---"
mash --namespace=cloud_prod --deadline=600 "Query(Fetch(Raw('cloud.BigtableDataRequest', 'bigtable.googleapis.com/frontend_server/handler_latencies'), {'instance': '$INSTANCE_ID', 'metric:method': RegexpMatch('(google.bigtable.v2.)?Bigtable(?:\\\\.|\\\\/).*'), 'project': '450300683590'}) | Point(DistributionCount()) | Window(Rate('5m')) | GroupBy(['metric:originator'], Sum()))" > mash_results_final.txt

echo "Verification complete. Results:"
cat mash_results_final.txt
