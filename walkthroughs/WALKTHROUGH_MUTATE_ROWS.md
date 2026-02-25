# Walkthrough: Implementing MutateRow and MutateRows in Java Sidecar

I have successfully implemented `MutateRow` and `MutateRows` functionality in the Java sidecar and proxied these calls from the Ruby client.

## Changes Made

### Proto Definition
- Updated `sidecar.proto` to include `MutateRow` and `MutateRows` RPCs.
- Defined structured request/response messages for mutation operations.

### Java Sidecar
- Implemented `mutateRow` and `mutateRows` in `SidecarServiceImpl.java`.
- Used the high-level Java Veneer client models (`RowMutation`, `BulkMutation`) for optimized execution.
- Handled `MutateRowsException` to return individual entry statuses back to Ruby.

### Ruby Client
- Updated `MutationOperations#mutate_row` to proxy calls to the sidecar.
- Updated `RowsMutator#apply_mutations` to bypass native Ruby retry logic and leverage the sidecar's internal Java-based retries.
- Added a `success?` method to `MutationOperations::Response` for consistency.

### Documentation & Infrastructure
- Created `SIDECAR.md` user guide covering:
    - **Benefits**: DirectPath support and high performance.
    - **Technical Implementation**: Packaging (stripped-down JRE, shaded JAR) and UDS-based gRPC communication.
    - **Caveats**: Idempotency risks when using server-side timestamps (`-1`).
    - **Performance Tuning**: Passing JVM flags via `BIGTABLE_SIDECAR_JVM_FLAGS`.
- Updated `Rakefile` to support passing JVM flags to the launcher.

## Verification Results

### Integration Tests
Ran the full integration test suite via `rake verify:install`. All 9 tests passed, including new mutation tests.

```text
Finished in 46.849127s, 0.1921 runs/s, 1.0032 assertions/s.

9 runs, 47 assertions, 0 failures, 0 errors, 0 skips
```

### New Tests Added
- `test_sidecar_mutate_row`: Verifies a single row mutation through the sidecar.
- `test_sidecar_mutate_rows`: Verifies a batch mutation (multiple rows) through the sidecar.

## Next Steps
- Review the idempotency behavior with a Bigtable expert to potentially synchronize Ruby and Java's handling of server-side timestamps.
