package com.example.sidecar;

import com.google.cloud.bigtable.data.v2.BigtableDataClient;
import com.google.cloud.bigtable.data.v2.BigtableDataSettings;
import com.google.cloud.bigtable.data.v2.models.Query;
import com.google.cloud.bigtable.data.v2.models.Row;
import com.google.cloud.bigtable.data.v2.models.RowCell;
import com.google.cloud.bigtable.data.v2.models.RowMutation;
import com.google.cloud.bigtable.data.v2.models.BulkMutation;
import com.google.cloud.bigtable.data.v2.models.MutateRowsException;

import com.google.bigtable.v2.BigtableGrpc;
import com.google.bigtable.v2.ReadRowsRequest;
import com.google.bigtable.v2.ReadRowsResponse;
import com.google.bigtable.v2.MutateRowRequest;
import com.google.bigtable.v2.MutateRowResponse;
import com.google.bigtable.v2.MutateRowsRequest;
import com.google.bigtable.v2.MutateRowsResponse;
import com.google.protobuf.BytesValue;
import com.google.protobuf.StringValue;
import com.google.rpc.Status;

import io.grpc.stub.StreamObserver;
import java.io.IOException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.logging.Level;
import java.util.logging.Logger;

public class BigtableProxyService extends BigtableGrpc.BigtableImplBase {
    private static final Logger logger = Logger.getLogger(BigtableProxyService.class.getName());

    private final ConcurrentHashMap<String, BigtableDataClient> clients = new ConcurrentHashMap<>();
    private final String defaultProject;
    private final String defaultInstance;

    private static final Pattern TABLE_NAME_PATTERN = Pattern
            .compile("projects/([^/]+)/instances/([^/]+)/tables/([^/]+)");

    public BigtableProxyService(String project, String instance) {
        this.defaultProject = project;
        this.defaultInstance = instance;
    }

    // Visible for testing
    protected BigtableDataClient getClient(String tableName, String appProfileId) throws IOException {
        Matcher matcher = TABLE_NAME_PATTERN.matcher(tableName);
        String project = defaultProject;
        String instance = defaultInstance;

        if (matcher.matches()) {
            project = matcher.group(1);
            instance = matcher.group(2);
        }

        if (project == null || instance == null) {
            throw new RuntimeException(
                    "Project and Instance IDs must be provided in table name or during sidecar startup.");
        }

        final String finalProject = project;
        final String finalInstance = instance;

        String clientKey = finalProject + "/" + finalInstance + "/" + (appProfileId == null ? "" : appProfileId);
        return clients.computeIfAbsent(clientKey, key -> {
            try {
                logger.info("Java Proxy: Initializing new client for " + key);
                BigtableDataSettings.Builder settingsBuilder = BigtableDataSettings.newBuilder()
                        .setProjectId(finalProject)
                        .setInstanceId(finalInstance);

                if (appProfileId != null && !appProfileId.isEmpty()) {
                    settingsBuilder.setAppProfileId(appProfileId);
                }

                BigtableDataSettings settings = settingsBuilder.build();
                return BigtableDataClient.create(settings);
            } catch (IOException e) {
                throw new RuntimeException("Java Proxy: Failed to create BigtableDataClient", e);
            }
        });
    }

    @Override
    public void readRows(ReadRowsRequest request, StreamObserver<ReadRowsResponse> responseObserver) {
        long startTime = System.nanoTime();
        try {
            String tableName = request.getTableName();
            String appProfileId = request.getAppProfileId();
            BigtableDataClient dataClient = getClient(tableName, appProfileId);

            Query query = Query.fromProto(request);

            ReadRowsResponse.Builder responseBuilder = ReadRowsResponse.newBuilder();
            int currentBytes = 0;
            // 2MB soft limit for chunking
            final int MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
            // 10ms max flush delay to prevent artificial latency for sparse rows
            final long MAX_FLUSH_DELAY_NANOS = 10_000_000L;
            long lastFlushTime = System.nanoTime();

            for (Row row : dataClient.readRows(query)) {
                java.util.List<RowCell> cells = row.getCells();
                if (cells.isEmpty()) {
                    // Empty row, just commit the key
                    ReadRowsResponse.CellChunk.Builder chunkBuilder = ReadRowsResponse.CellChunk.newBuilder()
                            .setRowKey(row.getKey())
                            .setCommitRow(true);
                    responseBuilder.addChunks(chunkBuilder.build());
                    currentBytes += row.getKey().size() + 10;
                } else {
                    for (int i = 0; i < cells.size(); i++) {
                        RowCell cell = cells.get(i);
                        ReadRowsResponse.CellChunk.Builder chunkBuilder = ReadRowsResponse.CellChunk.newBuilder();

                        int cellSize = 0;
                        // First chunk of the row gets the row key
                        if (i == 0) {
                            chunkBuilder.setRowKey(row.getKey());
                            cellSize += row.getKey().size();
                        }

                        chunkBuilder.setFamilyName(StringValue.newBuilder().setValue(cell.getFamily()).build());
                        chunkBuilder.setQualifier(BytesValue.newBuilder().setValue(cell.getQualifier()).build());
                        chunkBuilder.setTimestampMicros(cell.getTimestamp());
                        chunkBuilder.setValue(cell.getValue());

                        cellSize += cell.getFamily().length() + cell.getQualifier().size() + cell.getValue().size()
                                + 30;

                        // Last chunk of the row gets the commit marker
                        if (i == cells.size() - 1) {
                            chunkBuilder.setCommitRow(true);
                        }

                        responseBuilder.addChunks(chunkBuilder.build());
                        currentBytes += cellSize;
                    }
                }

                // Evaluate batch limits AFTER the full row is completely buffered
                long timeSinceLastFlush = System.nanoTime() - lastFlushTime;
                if (currentBytes >= MAX_RESPONSE_BYTES || timeSinceLastFlush >= MAX_FLUSH_DELAY_NANOS) {
                    if (responseBuilder.getChunksCount() > 0) {
                        responseObserver.onNext(responseBuilder.build());
                        responseBuilder.clear();
                        currentBytes = 0;
                        lastFlushTime = System.nanoTime();
                    }
                }
            }

            // Flush any remaining chunks
            if (responseBuilder.getChunksCount() > 0) {
                responseObserver.onNext(responseBuilder.build());
            }

            responseObserver.onCompleted();
        } catch (Exception e) {
            logger.log(Level.SEVERE, "Java Proxy ERROR: " + e.getMessage(), e);
            responseObserver.onError(e);
        } finally {
            long latencyNs = System.nanoTime() - startTime;
            SidecarMetrics.getInstance().recordReadRowsLatency(latencyNs);
        }
    }

    @Override
    public void mutateRow(MutateRowRequest request, StreamObserver<MutateRowResponse> responseObserver) {
        try {
            String tableName = request.getTableName();
            String appProfileId = request.getAppProfileId();
            BigtableDataClient dataClient = getClient(tableName, appProfileId);

            RowMutation rowMutation = RowMutation.fromProto(request);
            dataClient.mutateRow(rowMutation);

            responseObserver.onNext(MutateRowResponse.newBuilder().build());
            responseObserver.onCompleted();
        } catch (Exception e) {
            logger.log(Level.SEVERE, "Java Proxy ERROR: " + e.getMessage(), e);
            responseObserver.onError(e);
        }
    }

    @Override
    public void mutateRows(MutateRowsRequest request, StreamObserver<MutateRowsResponse> responseObserver) {
        try {
            String tableName = request.getTableName();
            String appProfileId = request.getAppProfileId();
            BigtableDataClient dataClient = getClient(tableName, appProfileId);

            BulkMutation bulkMutation = BulkMutation.fromProto(request);
            MutateRowsResponse.Builder responseBuilder = MutateRowsResponse.newBuilder();

            try {
                dataClient.bulkMutateRows(bulkMutation);
                // All succeeded
                for (int i = 0; i < request.getEntriesCount(); i++) {
                    responseBuilder.addEntries(MutateRowsResponse.Entry.newBuilder()
                            .setIndex(i)
                            .setStatus(Status.newBuilder().setCode(0).build()) // OK
                            .build());
                }
            } catch (MutateRowsException e) {
                // Initialize all as OK first
                for (int i = 0; i < request.getEntriesCount(); i++) {
                    responseBuilder.addEntries(MutateRowsResponse.Entry.newBuilder()
                            .setIndex(i)
                            .setStatus(Status.newBuilder().setCode(0).build())
                            .build());
                }

                for (MutateRowsException.FailedMutation failed : e.getFailedMutations()) {
                    int index = (int) failed.getIndex();
                    responseBuilder.setEntries(index, MutateRowsResponse.Entry.newBuilder()
                            .setIndex(index)
                            .setStatus(Status.newBuilder()
                                    .setCode(failed.getError().getStatusCode().getCode().ordinal())
                                    .setMessage(failed.getError().getMessage())
                                    .build())
                            .build());
                }
            }

            responseObserver.onNext(responseBuilder.build());
            responseObserver.onCompleted();
        } catch (Exception e) {
            logger.log(Level.SEVERE, "Java Proxy ERROR: " + e.getMessage(), e);
            responseObserver.onError(e);
        }
    }
}
