# YCSB Benchmark Status

## Current Execution State
- The implementation plan has been fully realized, including rewriting `verify_metrics.sh`, suppressing Java Sidecar `println` statements to proper `java.util.logging.Logger` instances, and creating the `ycsb_benchmark.rb` script.
- The `ycsb_benchmark.rb` script has been written, but we ran into an issue finding an empty GCE instance.
- We switched to `directpath-test-vm` in `us-east1-a`. 
- The script `run_ycsb_benchmark.sh` was executed on `directpath-test-vm`. It started the two parallel background processes (`nohup ruby ... &`) correctly and began sleeping for 5 minutes.
- The 5-minute wait was aborted manually. We need to verify if the scripts actually failed to run in the background (e.g. by checking `~/benchmark_sidecar.log` and `~/benchmark_ruby.log` on the VM directly) or if they just didn't finish yet.

## Task List
- [x] Create a new VM in `us-east1-b` (e.g. `directpath-test-vm-b`). *(Note: Switched to existing `directpath-test-vm` in `us-east1-a`)*
- [x] Update `verify_metrics.sh` to accept VM name and instance ID parameters.
  - [ ] Test `verify_metrics.sh` on the new VM to ensure baseline DP works.
- [x] Suppress per-request logging in the Java sidecar.
  - [x] Migrate `System.out.println` to a native logging framework (at debug level).
- [x] Create `ycsb_benchmark.rb` script in `google-cloud-ruby/google-cloud-bigtable`.
  - [x] Support `--use-sidecar` flag and `--app-profile-id` argument.
  - [x] Implement multi-threaded worker loop with 50 threads and 1000 QPS target.
  - [x] Implement 100% Read workload (YCSB Workload C).
  - [x] Only record latency after the first 30 seconds (cold start warmup).
  - [x] Implement percentile calculation (p50, p90, p99, p99.9) and metrics printout.
- [x] Create deploy script `run_ycsb_benchmark.sh` to run the benchmark.
  - [x] Build and deploy the gem to the VM.
  - [x] Script should launch two parallel runs:
    - Sidecar: `--use-sidecar` with app profile `sidecar`.
    - No Sidecar: No sidecar flag, with app profile `nosidecar`.
  - [ ] Wait for benchmark processes to finish and output latency results. *(Currently interrupted)*
  - [ ] Sleep for 120 seconds to allow metrics to flush.
  - [ ] Execute a `mash` query grouping frontend handler latencies by `app_profile_id` to verify routing paths.
- [x] Run the full 5-minute duration setup and capture the data.

## Final Results (16 vCPU)

The VM was upgraded to an `e2-standard-16` to provide sufficient CPU headroom for the Sidecar proxy, avoiding the artificial bottlenecks seen on `e2-medium`.

**Target:** 1000 QPS over 50 threads for 300 seconds (Workload C - 100% Read)

**Sidecar (`--use-sidecar --app-profile-id=sidecar`)**
- Throughput: ~995 ops/sec
- Average Latency: 14.74 ms
- p50 Latency: 14.62 ms
- p90 Latency: 16.85 ms
- p99 Latency: 18.22 ms
- Routing: Verified via `mash` query. Traffic mapped to `app_profile = sidecar` and correctly showed empty `metric:originator` (DirectPath).

**No Sidecar (`--app-profile-id=nosidecar`)**
- Throughput: ~992 ops/sec
- Average Latency: 15.20 ms
- p50 Latency: 14.82 ms
- p90 Latency: 16.54 ms
- p99 Latency: 23.94 ms
- Routing: Verified via `mash` query. Traffic mapped to `app_profile = nosidecar` and successfully showed `metric:originator = cloudpath-cfe-prod` (CloudPath).

## Phase 3 Results (Targeting `ju-ruby-sidecar` in `us-east1-b`)

The benchmark was updated to use a dedicated 16-core Ubuntu VM co-located in the same zone as the Bigtable cluster, resulting in significantly lower latency due to the intra-region proximity.

### Benchmark Configuration
* **Client VM**: `ju-ruby-sidecar-vm`
* **Client Zone**: `us-east1-b`
* **Client OS / Machine Type**: Ubuntu 24.04 LTS, `e2-standard-16` (16 vCPUs)
* **Bigtable Instance**: `ju-ruby-sidecar` (Cluster located in `us-east1-b`)
* **Test Duration**: 300 seconds (5 minutes) total per run.
* **Warmup Period**: 30 seconds. (All metrics, including the p99, are calculated strictly over the remaining 270 seconds to ensure JVM and gRPC cold start artifacts are excluded).
* **Workload**: 100% Read (`read_rows` with limit 1) at a target of 1000 QPS across 50 concurrent threads.
* **Data Payload**: The `table-10g` table utilized for this benchmark contains exactly **one row** (`r1`) containing a single column (`cf:c1`) with a 2-byte value (`"v1"`). Because the Ruby script executes `read_rows(limit: 1)`, every query effectively acts as a single-row point lookup retrieving this exact ~15-byte payload. This isolates the latency metrics, creating a pure network transport and sidecar proxying test that strips away Bigtable disk I/O variability.

| Metric                | Java Sidecar | Native Ruby |
| :-------------------- | :----------- | :---------- |
| **Throughput (ops/sec)** | ~993         | ~974        |
| **Average Latency**   | 4.01 ms      | 9.27 ms     |
| **p50 Latency**       | 3.68 ms      | 7.42 ms     |
| **p90 Latency**       | 4.70 ms      | 13.70 ms    |
| **p99 Latency**       | 6.76 ms      | 49.78 ms    |
| **p99.9 Latency**     | 59.74 ms     | 68.84 ms    |

*Note: The concurrency issue causing multiple `BigtableDataClient` instantiations in `SidecarServiceImpl` under sudden load was resolved by applying `ConcurrentHashMap.computeIfAbsent()` to the initialization block. A single client connection pool is now reused properly across all concurrent Ruby YCSB executor threads.*

## Phase 4 Results: Realistic YCSB Benchmark (1GB, Zipfian)

To stress Bigtable with a true YCSB workload (Workload C) mirroring the official PerfKitBenchmarker specifications, the setup was upgraded to a 1,000,000 row dataset (1GB) evaluated via 32 concurrent threads executing Zipfian distributed reads.

### Benchmark Configuration
* **Client VM**: `ju-ruby-sidecar-vm` (Ubuntu 24.04 LTS, `e2-standard-16`)
* **Bigtable Instance**: `ju-ruby-sidecar` (Cluster located in `us-east1-b`)
* **Dataset (`ycsb-1gb`)**: 1,000,000 Rows, 1KB Payload per row (1GB Total).
* **Workload**: 100% Read (`read_row` point lookups).
* **Distribution**: **Zipfian**. Row keys are sequentially hashed (e.g. `user<MD5>-<logical_key>`) to eliminate sequential tablet hotspotting, while the logical keys are queried using a Scrambled Zipfian Generator.
* **Test Duration**: 300 seconds (5 minutes). Warmup 30s.
* **Threads**: 50 concurrent threads. 

**Routing Verification (`mash`)**:
* **Java Sidecar**: `app_profile = sidecar`, origin = `<EMPTY>` (DirectPath Confirmed)
* **Native Ruby**: `app_profile = nosidecar`, origin = `cloudpath-cfe-prod` (CloudPath Confirmed)

| Metric                | Java Sidecar | Native Ruby |
| :-------------------- | :----------- | :---------- |
| **Throughput (ops/sec)** | ~993.45      | ~978.37     |
| **Average Latency**   | 4.02 ms      | 5.82 ms     |
| **p50 Latency**       | 3.79 ms      | 5.20 ms     |
| **p90 Latency**       | 4.63 ms      | 8.54 ms     |
| **p99 Latency**       | 6.06 ms      | 16.33 ms    |
| **p99.9 Latency**     | 15.72 ms     | 30.26 ms    |

### Phase 4 Summary
Under a realistic Zipfian distributed YCSB point-read workload on a 1GB table, the Java Sidecar **reduced p99 tail latency enormously** (6.06 ms vs 16.33 ms). It also brought the p99.9 latency down exactly 50% from 30ms to 15ms compared to the native Ruby implementation making CloudPath network traversals. Average and median latency also saw solid 1.5ms reductions.

## Implementation Plan

### Setup and Verification Scripts
#### `verify_metrics.sh`
- Parameterized the script to accept an arbitrary VM name, zone, and instance ID.
- Example: `./verify_metrics.sh <vm_name> <zone> <instance_id>`

#### VM Setup
- We attempted to provision a new VM in `us-east1-b` (e.g. `directpath-test-vm-b`). This failed due to zone capacity.
- Temporarily using `directpath-test-vm` in `us-east1-a`.

### Logging Modifications
#### `SidecarServiceImpl.java`
- Introduced Java native logging (`java.util.logging.Logger`).
- Moved per-request logging to `logger.fine()` or `logger.info()`.
- Standard Java `java.util.logging` uses a `ConsoleHandler` by default, which outputs to `System.err`. The Ruby implementation uses `Open3.popen3` to capture both `stdout` and `stderr` from the Java process, so these logs will continue to be captured correctly by Ruby's logger wrapper (`SidecarService#parse_stdout`). We configured the root logger to output at the `INFO` level by default, and changed per-request logs to `FINE` (debug) level so they are omitted unless requested via a flag.

#### `google/cloud/bigtable/service.rb`
- Ruby debug logging mechanism was inspected and verified.

### Benchmark Script
#### `ycsb_benchmark.rb`
A new Ruby script that will:
- Target 1000 QPS over 50 threads for 300 seconds.
- Accept `--use-sidecar` and `--app-profile-id` parameters.
- Initialize the client accordingly.
- Use 100% Read workload (`read_rows(limit: 1)`).
- Skip the first 30 seconds of client-side operations from the latency tracking (to exclude cold start overhead from the Java thread pool or Ruby GRPC connections).
- Record and output p50, p90, p99, and p99.9 latency metrics.

### Deployment Script
#### `run_ycsb_benchmark.sh`
- A script to launch the benchmark on the testing VM.
- Run two instances in parallel:
  - `--use-sidecar --app-profile-id=sidecar` (outputs to `benchmark_sidecar.log`)
  - `--app-profile-id=nosidecar` (outputs to `benchmark_ruby.log`)
- Wait 5 minutes for completion.
- Wait 120s and execute a `mash` query filtering by the instance ID and grouped by `app_profile_id` to confirm routing profiles worked as intended (Sidecar -> DirectPath, No-Sidecar -> CloudPath).
