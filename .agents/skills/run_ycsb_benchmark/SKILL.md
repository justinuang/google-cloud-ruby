---
name: Run YCSB Benchmark
description: How to run the YCSB benchmark to test Bigtable DirectPath Sidecar using the c3 VM
---

# Run YCSB Benchmark

When you need to test the performance of the Java Sidecar vs Native Ruby, you can run the `run_ycsb_benchmark.sh` script. This benchmark performs 100% Read point lookups (YCSB Workload C) against a 100GB Bigtable dataset with a Zipfian distribution to simulate production-grade workloads and tail latency distributions.

## Pre-requisites
1. **Testing VM**: Typically a compute-optimized VM like `ju-ruby-sidecar-c3-vm` in `us-east1-b` to provide consistent latency and high CPU burst frequency.
2. **Environment**: The VM must have Ruby, Java (JRE), and the necessary gRPC/Bigtable dependencies installed.
3. **Script Location**: `google-cloud-ruby/google-cloud-bigtable/run_ycsb_benchmark.sh`.

## Parameters
The `run_ycsb_benchmark.sh` script accepts the following positional parameters:
1. `VM_NAME` (Default: `ju-ruby-sidecar-vm`): The name of the GCE instance.
2. `VM_ZONE` (Default: `us-east1-b`): The GCP zone where the VM is located.
3. `DURATION` (Default: `300`): The duration of the benchmark in seconds.

Example:
```bash
./run_ycsb_benchmark.sh ju-ruby-sidecar-c3-vm us-east1-b 600
```

## Steps
1. Navigate to the `google-cloud-ruby/google-cloud-bigtable` directory.
2. Execute the script with appropriate parameters.
3. The script will:
    - Build the sidecar gem locally.
    - Deploy the gem and necessary Ruby scripts (`ycsb_benchmark.rb`) to the VM.
    - Run three parallel benchmark axes:
        - **Sidecar (DirectPath)**: Uses the Java sidecar with DirectPath enabled.
        - **Sidecar (CloudPath)**: Uses the Java sidecar with DirectPath disabled (forces CloudPath).
        - **Native Ruby**: Uses the standard Ruby client (CloudPath).
    - Wait for all processes to complete.
    - Fetch and display the tail metrics (p50 through p99.9) for all three axes.

## Interpreting Results
The benchmark outputs latency metrics (in milliseconds) and throughput (ops/sec) for each test axis.
- **p50 (Median)**: General performance baseline.
- **p99 / p99.9 (Tail)**: Crucial for understanding the impact of GC pauses and network jitter. The Java Sidecar typically shows significantly lower tail latencies than Native Ruby under heavy load.

## Updating Benchmark Status
After a successful run, you should:
1. **Document results**: Update `YCSB_BENCHMARK_STATUS.md` by adding a new "Phase" section summarizing the test configuration and the resulting metric comparison table.
2. **Persist Logs**: Copy the fetched log files from `tmp/benchmark/` to the `google-cloud-bigtable/benchmark_results/` directory in the git repository to maintain a historical record of the performance over time.

## Troubleshooting & Logs
- **Local Logs**: Aggregated results are fetched to `tmp/benchmark/*.log`.
- **VM Logs**: Raw execution logs are stored on the VM at `~/benchmark_sidecar.log`, `~/benchmark_sidecar_cloudpath.log`, and `~/benchmark_ruby.log`.
- **Java Sidecar Logs**: Internal Java logs (captured via `stderr`) are included in the sidecar log files. If the sidecar fails to start, check for "Java Proxy ERROR" in these files.

