## Explanation of Jetstream API & `JetstreamRow` mapping
The existing sidecar implementation parses incoming GRPC bytes into `com.google.bigtable.v2.ReadRowsRequest` and then uses the Veneer client to execute the read. The Veneer client returns `com.google.cloud.bigtable.data.v2.models.Row`, which the sidecar then manually unpacks and reconstructs into a `SidecarRow` protocol buffer. 

Jetstream is the internal experimental bidirectional streaming API for Bigtable. The Java Jetstream implementation exposes an internal `Client` and `TableAsync` class. `TableAsync.readRow` returns `CompletableFuture<SessionReadRowResponse>`. This response object contains a `com.google.bigtable.v2.Row`.

Because `ReadRowsResponse.CellChunk` is nearly identical to `com.google.bigtable.v2.Row`'s structure (it's essentially a flattened list of column families and cells), we can bypass the Veneer (`models.Row`) conversion entirely when using Jetstream. Jetstream returns the same native protocol buffer messages that the Bigtable Data API uses.

Between Jetstream and non-Jetstream, **we will not be able to share the implementation logic of the loop itself** because the non-Jetstream client (Veneer) iterates over `models.Row` and `models.RowCell`, whereas the Jetstream client returns `com.google.bigtable.v2.Row`. However, the logic to construct the gRPC `ReadRowsResponse` and manage the metrics will remain identical.

<details>
<summary>Jetstream ReadRows Snippet (Java)</summary>

```java
// Inside BigtableProxyService.java readRows
com.google.cloud.bigtable.data.v2.internal.api.Client jetstreamClient = getJetstreamClient(tableName, appProfileId);
try (TableAsync tableAsync = jetstreamClient.getTable(request.getTableName())) {
    logger.fine("Java Proxy: Executing Jetstream readRow for " + request.getTableName());
    
    // Jetstream point-lookup
    ByteString rowKey = request.getRows().getRowKeys(0);
    com.google.bigtable.v2.Row row = tableAsync.readRow(rowKey).get().getRow();

    ReadRowsResponse.Builder responseBuilder = ReadRowsResponse.newBuilder();
    int currentBytes = 0;
    final int MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
    final int MAX_CHUNKS = 1000;

    if (row != null) {
        java.util.List<com.google.bigtable.v2.Family> families = row.getFamiliesList();
        if (families.isEmpty()) {
            ReadRowsResponse.CellChunk.Builder chunkBuilder = ReadRowsResponse.CellChunk.newBuilder()
                    .setRowKey(row.getKey())
                    .setCommitRow(true);
            responseBuilder.addChunks(chunkBuilder.build());
        } else {
            boolean isFirstChunk = true;
            for (com.google.bigtable.v2.Family family : families) {
                for (com.google.bigtable.v2.Column column : family.getColumnsList()) {
                    for (int i = 0; i < column.getCellsCount(); i++) {
                        com.google.bigtable.v2.Cell cell = column.getCells(i);
                        ReadRowsResponse.CellChunk.Builder chunkBuilder = ReadRowsResponse.CellChunk.newBuilder();
                        
                        int cellSize = 0;
                        if (isFirstChunk) {
                            chunkBuilder.setRowKey(row.getKey());
                            cellSize += row.getKey().size();
                            isFirstChunk = false;
                        }

                        chunkBuilder.setFamilyName(StringValue.newBuilder().setValue(family.getName()).build());
                        chunkBuilder.setQualifier(BytesValue.newBuilder().setValue(column.getQualifier()).build());
                        chunkBuilder.setTimestampMicros(cell.getTimestampMicros());
                        chunkBuilder.setValue(cell.getValue());
                        
                        cellSize += family.getName().length() + column.getQualifier().size() + cell.getValue().size() + 30;

                        // If this is the very last cell of the very last column of the very last family
                        if (family == families.get(families.size() - 1) && 
                            column == family.getColumnsList().get(family.getColumnsCount() - 1) &&
                            i == column.getCellsCount() - 1) {
                            chunkBuilder.setCommitRow(true);
                        }

                        responseBuilder.addChunks(chunkBuilder.build());
                        currentBytes += cellSize;

                        if (currentBytes >= MAX_RESPONSE_BYTES || responseBuilder.getChunksCount() >= MAX_CHUNKS) {
                            responseObserver.onNext(responseBuilder.build());
                            responseBuilder.clear();
                            currentBytes = 0;
                        }
                    }
                }
            }
        }
    }
    
    if (responseBuilder.getChunksCount() > 0) {
        responseObserver.onNext(responseBuilder.build());
    }
}
```
</details>

## Proposed Changes

### Java Sidecar Configuration
#### [NEW] `java-bigtable-jetstream`
- Copy the `java-bigtable-jetstream` repository into the `ruby-prototype-worktree2/google-cloud-ruby/` active workspace.
- Build the `java-bigtable-jetstream/google-cloud-bigtable` module and install it to the local maven cache using `mvn install`.
- Update the sidecar's `pom.xml` to depend on this installed version `2.62.1-session-SNAPSHOT`.

### Java Sidecar Configuration
#### [MODIFY] [pom.xml](file:///usr/local/google/home/justinuang/ruby-prototype-worktree2/google-cloud-ruby/google-cloud-bigtable/sidecar/pom.xml)
- Override the `google-cloud-bigtable` dependency to use the Jetstream version (`2.62.1-session-SNAPSHOT`).
- Add explicitly the version `<version>2.62.1-session-SNAPSHOT</version>`. 

### Java Sidecar Implementation
#### [MODIFY] [BigtableProxyService.java](file:///usr/local/google/home/justinuang/ruby-prototype-worktree2/google-cloud-ruby/google-cloud-bigtable/sidecar/src/main/java/com/example/sidecar/BigtableProxyService.java)
- We will intercept the incoming `ReadRowsRequest` and `MutateRowRequest` on their existing methods.
- We will check for a gRPC metadata header: `x-use-jetstream: true`. 
  - If the header is present **AND** the `ReadRowsRequest` contains exactly one row key (a point read), route it to the Jetstream client via `tableAsync.readRow()`.
  - For `MutateRowRequest`, route it straight to `tableAsync.mutateRow()`.
  - If the conditions are not met, fall back to the standard Veneer `BigtableDataClient`.
- For Jetstream `readRows` point lookups, execute `tableAsync.readRow()`. Create `CellChunk`s from the returned `com.google.bigtable.v2.Row` in a dedicated helper method, replicating the `ReadRowsResponse` stream exactly. 
  - *Crucially, we only need to call `setRowKey()` on the very first `CellChunk` builder if the header is present.*
- Add a response gRPC header (e.g., `x-jetstream-used: true`) so the Ruby client can verify which client was actually invoked for the test.

### Ruby Client Implementation
#### [MODIFY] Ruby Bigtable Client Structure
- Add a config option `jetstream: true` when instantiating `Bigtable::Client`. Only route through Jetstream if this is explicitly enabled.
- When making a point-lookup `read_rows` call or a `mutate_row` call, if the config is enabled, inject the gRPC metadata header (`x-use-jetstream: true`) into the sidecar request.
- Ensure the result from `read_rows` handles fetching the returned trailing gRPC headers to observe if Jetstream actually executed the request.

### Automated Tests
- Run existing Sidecar tests to ensure basic parity (e.g. `test/google/cloud/bigtable/sidecar_integration_test.rb`).
  - Command: `bundle exec rake test`
- Build and run the `java-sidecar` unit and integration tests (if any).
  - Command: `mvn test` in the `sidecar` directory.
- Add a dedicated integration test that enables Jetstream in the client, issues a point-read query, and explicitly asserts on the `x-jetstream-used` response header to prove Jetstream was exercised rather than falling back.

### Manual Verification
- Start the server with the Jetstream configuration.
- Add an ad-hoc logging line inside `SidecarServiceImpl.java` to print "Using Jetstream!" to verify the routing hits the new Bidi implementation.
- Run a benchmark or dual-client verification script to ensure traffic completes properly.
