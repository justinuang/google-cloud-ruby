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
import io.grpc.Context;
import io.grpc.Contexts;
import io.grpc.Deadline;
import io.grpc.ForwardingServerCall;
import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

import com.google.bigtable.v2.SessionMutateRowRequest;
import com.google.bigtable.v2.SessionMutateRowResponse;
import com.google.bigtable.v2.SessionReadRowRequest;
import com.google.bigtable.v2.SessionReadRowResponse;
import com.google.cloud.bigtable.data.v2.internal.api.TableAsync;
import com.google.cloud.bigtable.data.v2.internal.api.Client;
import com.google.cloud.bigtable.data.v2.internal.api.ClientSettings;
import com.google.cloud.bigtable.data.v2.internal.api.InstanceName;
import com.google.bigtable.v2.OpenTableRequest;

import java.io.IOException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.logging.Level;
import java.util.logging.Logger;

public class BigtableProxyService extends BigtableGrpc.BigtableImplBase {
    private static final Logger logger = Logger.getLogger(BigtableProxyService.class.getName());

    private final ConcurrentHashMap<String, BigtableDataClient> clients = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, TableAsync> jetstreamClients = new ConcurrentHashMap<>();
    private final String defaultProject;
    private final String defaultInstance;

    public static final Context.Key<Boolean> USE_JETSTREAM_KEY = Context.key("use-jetstream");
    public static final Context.Key<AtomicBoolean> JETSTREAM_USED_KEY = Context.key("jetstream-used");

    public static final ServerInterceptor JETSTREAM_INTERCEPTOR = new ServerInterceptor() {
        @Override
        public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
                ServerCall<ReqT, RespT> call,
                Metadata headers,
                ServerCallHandler<ReqT, RespT> next) {

            String headerValue = headers.get(Metadata.Key.of("x-use-jetstream", Metadata.ASCII_STRING_MARSHALLER));
            boolean requestedJetstream = "true".equalsIgnoreCase(headerValue);

            AtomicBoolean jetstreamUsed = new AtomicBoolean(false);
            Context ctx = Context.current()
                    .withValue(USE_JETSTREAM_KEY, requestedJetstream)
                    .withValue(JETSTREAM_USED_KEY, jetstreamUsed);

            ServerCall<ReqT, RespT> wrappedCall = new ForwardingServerCall.SimpleForwardingServerCall<ReqT, RespT>(
                    call) {
                @Override
                public void close(io.grpc.Status status, Metadata trailers) {
                    if (jetstreamUsed.get()) {
                        trailers.put(Metadata.Key.of("x-jetstream-used", Metadata.ASCII_STRING_MARSHALLER), "true");
                    }
                    super.close(status, trailers);
                }
            };

            return Contexts.interceptCall(ctx, wrappedCall, headers, next);
        }
    };

    private static final AtomicLong lastJetstreamLogNs = new AtomicLong(0);

    private static void logJetstreamUsage() {
        long now = System.nanoTime();
        long last = lastJetstreamLogNs.get();
        if (now - last > 10_000_000_000L) {
            if (lastJetstreamLogNs.compareAndSet(last, now)) {
                logger.info("Using Jetstream!");
            }
        }
    }

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

    protected TableAsync getJetstreamTableAsync(String tableName, String appProfileId) throws IOException {
        Matcher matcher = TABLE_NAME_PATTERN.matcher(tableName);
        String project = defaultProject;
        String instance = defaultInstance;
        String table = "";

        if (matcher.matches()) {
            project = matcher.group(1);
            instance = matcher.group(2);
            table = matcher.group(3);
        }

        if (project == null || instance == null || table.isEmpty()) {
            throw new RuntimeException("Invalid table name: " + tableName);
        }

        final String finalProject = project;
        final String finalInstance = instance;
        final String finalTableId = table;

        String clientKey = finalProject + "/" + finalInstance + "/" + finalTableId + "/"
                + (appProfileId == null ? "" : appProfileId);
        return jetstreamClients.computeIfAbsent(clientKey, key -> {
            try {
                logger.info("Java Proxy: Initializing new Jetstream client for " + key);

                InstanceName jInstanceName = InstanceName.builder()
                        .setProjectId(finalProject)
                        .setInstanceId(finalInstance)
                        .build();

                ClientSettings.Builder settingsBuilder = ClientSettings.builder()
                        .setInstanceName(jInstanceName);

                if (appProfileId != null && !appProfileId.isEmpty()) {
                    settingsBuilder.setAppProfileId(appProfileId);
                } else {
                    settingsBuilder.setAppProfileId("");
                }

                Client jetstreamClient = new Client(settingsBuilder.build());
                return jetstreamClient.openTableAsync(finalTableId, OpenTableRequest.Permission.PERMISSION_READ_WRITE);
            } catch (IOException e) {
                throw new RuntimeException("Java Proxy: Failed to create JetstreamClient", e);
            }
        });
    }

    @Override
    public void readRows(ReadRowsRequest request, StreamObserver<ReadRowsResponse> responseObserver) {
        long startTime = System.nanoTime();
        try {
            String tableName = request.getTableName();
            String appProfileId = request.getAppProfileId();

            if (Boolean.TRUE.equals(USE_JETSTREAM_KEY.get())
                    && request.getRows().getRowKeysCount() == 1
                    && request.getRows().getRowRangesCount() == 0) {

                JETSTREAM_USED_KEY.get().set(true);
                logJetstreamUsage();

                SessionReadRowRequest.Builder jetstreamReq = SessionReadRowRequest.newBuilder()
                        .setKey(request.getRows().getRowKeys(0));

                if (request.hasFilter()) {
                    jetstreamReq.setFilter(request.getFilter());
                }

                com.google.bigtable.v2.Row rowResp = getJetstreamTableAsync(tableName, appProfileId)
                        .readRow(jetstreamReq.build(), Deadline.after(1, TimeUnit.MINUTES))
                        .get()
                        .getRow();

                if (rowResp.getKey().isEmpty()) {
                    responseObserver.onCompleted();
                    return;
                }

                ReadRowsResponse.Builder responseBuilder = ReadRowsResponse.newBuilder();
                java.util.List<com.google.bigtable.v2.Family> families = rowResp.getFamiliesList();

                if (families.isEmpty()) {
                    ReadRowsResponse.CellChunk.Builder chunkBuilder = ReadRowsResponse.CellChunk.newBuilder()
                            .setRowKey(rowResp.getKey())
                            .setCommitRow(true);
                    responseBuilder.addChunks(chunkBuilder.build());
                } else {
                    boolean isFirst = true;
                    for (int fIdx = 0; fIdx < families.size(); fIdx++) {
                        com.google.bigtable.v2.Family family = families.get(fIdx);
                        java.util.List<com.google.bigtable.v2.Column> columns = family.getColumnsList();
                        for (int cIdx = 0; cIdx < columns.size(); cIdx++) {
                            com.google.bigtable.v2.Column column = columns.get(cIdx);
                            java.util.List<com.google.bigtable.v2.Cell> jCells = column.getCellsList();

                            for (int cellIdx = 0; cellIdx < jCells.size(); cellIdx++) {
                                com.google.bigtable.v2.Cell jCell = jCells.get(cellIdx);

                                ReadRowsResponse.CellChunk.Builder chunkBuilder = ReadRowsResponse.CellChunk
                                        .newBuilder();

                                if (isFirst) {
                                    chunkBuilder.setRowKey(rowResp.getKey());
                                    isFirst = false;
                                }

                                chunkBuilder.setFamilyName(com.google.protobuf.StringValue.newBuilder()
                                        .setValue(family.getName()).build());
                                chunkBuilder.setQualifier(com.google.protobuf.BytesValue.newBuilder()
                                        .setValue(column.getQualifier()).build());
                                chunkBuilder.setTimestampMicros(jCell.getTimestampMicros());
                                chunkBuilder.setValue(jCell.getValue());

                                if (fIdx == families.size() - 1 && cIdx == columns.size() - 1
                                        && cellIdx == jCells.size() - 1) {
                                    chunkBuilder.setCommitRow(true);
                                }

                                responseBuilder.addChunks(chunkBuilder.build());
                            }
                        }
                    }
                }

                responseObserver.onNext(responseBuilder.build());
                responseObserver.onCompleted();
                return;
            }

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

            if (Boolean.TRUE.equals(USE_JETSTREAM_KEY.get())) {
                JETSTREAM_USED_KEY.get().set(true);
                logJetstreamUsage();

                SessionMutateRowRequest jetstreamReq = SessionMutateRowRequest.newBuilder()
                        .setKey(request.getRowKey())
                        .addAllMutations(request.getMutationsList())
                        .build();

                getJetstreamTableAsync(tableName, appProfileId)
                        .mutateRow(jetstreamReq, Deadline.after(1, TimeUnit.MINUTES))
                        .get();

                responseObserver.onNext(MutateRowResponse.newBuilder().build());
                responseObserver.onCompleted();
                return;
            }

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
