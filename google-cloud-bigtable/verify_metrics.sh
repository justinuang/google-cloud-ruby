#!/bin/bash
set -ex

echo "--- Step 1: Building and Deploying Gem ---"
cd /usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable

echo "Building Java sidecar..."
cd sidecar
mvn clean package -DskipTests
cd ..

echo "Cleaning up old gems..."
rm -f google-cloud-bigtable-*.gem

echo "Building gem..."
mkdir -p lib/google/cloud/bigtable/runtime/app
cp sidecar/target/java-sidecar-1.0-SNAPSHOT.jar lib/google/cloud/bigtable/runtime/app/sidecar.jar
rm -rf lib/google/cloud/bigtable/runtime/app/dependency
cp -r sidecar/target/dependency lib/google/cloud/bigtable/runtime/app/
chmod -R a+rX lib/google/cloud/bigtable/runtime/app/dependency
gem build google-cloud-bigtable.gemspec
GEM_FILE=$(ls -t google-cloud-bigtable-*.gem | head -n1)

echo "Copying $GEM_FILE and direct_access_flood.rb to VM..."
gcloud compute scp --zone=us-east1-a $GEM_FILE directpath-test-vm:~/
gcloud compute scp --zone=us-east1-a direct_access_flood.rb directpath-test-vm:~/

echo "Uninstalling old gem and installing new gem on VM..."
gcloud compute ssh --zone=us-east1-a directpath-test-vm --command="sudo gem uninstall -aIx google-cloud-bigtable || true; sudo gem install --local ~/$GEM_FILE"

echo "--- Step 2: Running Traffic Generator ---"
gcloud compute ssh --zone=us-east1-a directpath-test-vm --command="nohup ruby ~/direct_access_flood.rb > ~/directpath_flood.log 2>&1 &"

echo "--- Step 3: Verifying Version Logs ---"
# Wait a few seconds for the script to initialize and sidecar to start
sleep 5
echo "Checking VM logs for VERIFICATION_RUN_001 string..."
# We use || to handle the case where grep fails to find the string.
# If grep doesn't find the string, it exits with a non-zero code (1), which triggers the || condition.
# The { ...; exit 1; } block then prints a warning and explicitly exits the whole script with an error code (1),
# stopping the verification process immediately since the correct code isn't running.
gcloud compute ssh --zone=us-east1-a directpath-test-vm --command="cat ~/directpath_flood.log | grep VERIFICATION_RUN_001" || { echo "WARNING: Version string not found in logs!"; exit 1; }

echo "--- Step 4: Waiting for Monarch Metrics (120 seconds) ---"
echo "Sleeping for 120 seconds to allow metrics to propagate to Monarch..."
sleep 120

echo "--- Step 5: Querying Monarch ---"
mash --namespace=cloud_prod --deadline=600 "Query(Fetch(Raw('cloud.BigtableDataRequest', 'bigtable.googleapis.com/frontend_server/handler_latencies'), {'instance': 'autopilot-rm-test', 'metric:method': RegexpMatch('(google.bigtable.v2.)?Bigtable(?:\\\\.|\\\\/).*'), 'project': '450300683590'}) | Point(DistributionCount()) | Window(Rate('5m')) | GroupBy(['metric:originator'], Sum()))" > mash_results_final.txt

echo "Verification complete. Results:"
cat mash_results_final.txt
