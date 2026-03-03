---
description: Run the YCSB benchmark to test Bigtable DirectPath Sidecar vs Native Ruby
---

# Run YCSB Benchmark Workflow

When you need to test the performance of the Java Sidecar vs Native Ruby, follow this workflow to run the `run_ycsb_benchmark.sh` script and persist the results. This benchmark performs 100% Read point lookups (YCSB Workload C) against a 100GB Bigtable dataset with a Zipfian distribution.

## Pre-requisites
- **Testing VM**: This workflow always targets the compute-optimized VM `ju-ruby-sidecar-c3-vm` in `us-east1-b`.

## Parameters
- `<PHASE_NAME>`: A descriptive name for this specific benchmark run (e.g., `baseline_c3_test`). Avoid generic numbered phases.

// turbo-all
## Steps

1. Navigate to the testing directory from the repository root.
```bash
cd google-cloud-bigtable
```

2. Execute the `run_ycsb_benchmark.sh` script. Always use `ju-ruby-sidecar-c3-vm` and `us-east1-b` for the VM and Zone parameters to ensure consistent testing. Supply the desired `DURATION` and `<PHASE_NAME>`. User descriptive phase names instead of numbers!
```bash
# Example usage to be dynamically updated with actual parameters
./run_ycsb_benchmark.sh ju-ruby-sidecar-c3-vm us-east1-b 300 <PHASE_NAME>
```
3. Interpret the output metrics to understand the performance differences:
   - **p50 (Median)**: General performance baseline.
   - **p99 / p99.9 (Tail)**: Crucial for understanding the impact of GC pauses and network jitter.

4. Apply the parsed outputs to `YCSB_BENCHMARK_STATUS.md` by appending a new "Phase" section at the bottom. Summarize the test configuration and include the resulting metric comparison table.

5. **Persist Logs**: Copy the fetched log files from the temporary `tmp/` folder into the permanent `benchmark_results/` directory so they are tracked in version control.
```bash
mkdir -p benchmark_results/<PHASE_NAME> && cp tmp/<PHASE_NAME>/*.log benchmark_results/<PHASE_NAME>/
```
