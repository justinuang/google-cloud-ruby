# Walkthrough: Java-Side Sidecar Tracking

I have moved usage tracking to the Java sidecar. The Ruby client now queries the sidecar's statistics to verify that operations are actually processed by the Java code.

## Changes Made

### Java Sidecar
- [SidecarServiceImpl.java](file:///usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable/sidecar/src/main/java/com/example/sidecar/SidecarServiceImpl.java): Added an `AtomicLong` to track `readRows` calls and implemented the `getStats` RPC.

### Infrastructure & Protos
- [Rakefile](file:///usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable/Rakefile): Added a `proto:generate` task to keep Ruby protos in sync with `sidecar.proto`. Integrated it into the `sidecar:build` task.
- Regenerated Ruby protos in `lib/google/cloud/bigtable/sidecar_proto/`.

### Ruby Client
- [service.rb](file:///usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable/lib/google/cloud/bigtable/service.rb): Added `sidecar_stats` method to access the sidecar's internal counters.

### Verification Tests
- [install_verification.rb](file:///usr/local/google/home/justinuang/ruby-prototype/google-cloud-ruby/google-cloud-bigtable/test/verification/install_verification.rb): Added `test_sidecar_statistics` to assert that the sidecar's counter increases after a `read_rows` call.

## Verification Results

### Automated Tests
Run `bundle exec rake verify:install`.

```text
Run options: --seed 59852

# Running:

.   [SIDECAR] Java Sidecar: Starting gRPC server on /tmp/bigtable-sidecar20260225-422058-58vl0t/sidecar.sock
   [SIDECAR] Java Sidecar: Server started, listening on /tmp/bigtable-sidecar20260225-422058-58vl0t/sidecar.sock
   [SIDECAR] Java Sidecar: Signaled readiness to FIFO: /tmp/bigtable-sidecar20260225-422058-58vl0t/ready.fifo
.   [SIDECAR] Java Sidecar: Finished streaming 5 rows.
.   [SIDECAR] Java Sidecar: Received readRows call. Request bytes size: 81
...
7 runs, 34 assertions, 0 failures, 0 errors, 0 skips
```

All 7 verification tests passed, confirming end-to-end functionality of the statistics tracking.
