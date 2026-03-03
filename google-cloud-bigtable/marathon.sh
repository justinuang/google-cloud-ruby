#!/bin/bash
DURATION=${1:-28800}
echo "Starting 8-hour Marathon (Duration: ${DURATION}s)"
rm -f ~/benchmark_sidecar.log ~/benchmark_sidecar_cloudpath.log ~/benchmark_ruby.log

# DirectPath Sidecar
ruby ~/ycsb_benchmark.rb --qps=500 --use-sidecar --app-profile-id=sidecar --duration=${DURATION} > ~/benchmark_sidecar.log 2>&1 &
PID1=$!

# CloudPath Sidecar
BIGTABLE_SIDECAR_DISABLE_DIRECTPATH=true ruby ~/ycsb_benchmark.rb --qps=500 --use-sidecar --app-profile-id=sidecarcloudpath --duration=${DURATION} > ~/benchmark_sidecar_cloudpath.log 2>&1 &
PID2=$!

# Native Ruby
ruby ~/ycsb_benchmark.rb --qps=500 --app-profile-id=nosidecar --duration=${DURATION} > ~/benchmark_ruby.log 2>&1 &
PID3=$!

echo "Processes started: PID1=$PID1 (DirectPath), PID2=$PID2 (CloudPath), PID3=$PID3 (Native Ruby)"
wait $PID1 $PID2 $PID3
echo "Marathon finished."
