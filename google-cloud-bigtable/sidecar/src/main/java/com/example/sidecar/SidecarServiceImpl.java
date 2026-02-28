package com.example.sidecar;

import com.google.cloud.bigtable.data.v2.BigtableDataClient;
import com.google.cloud.bigtable.data.v2.BigtableDataSettings;
import com.google.cloud.bigtable.data.v2.models.Query;
import com.google.cloud.bigtable.data.v2.models.Row;
import com.google.protobuf.ByteString;
import io.grpc.stub.StreamObserver;
import java.io.IOException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import com.google.bigtable.v2.ReadRowsRequest;
import com.google.bigtable.v2.MutateRowRequest;
import com.google.bigtable.v2.MutateRowsRequest;
import com.google.cloud.bigtable.data.v2.models.RowMutation;
import com.google.cloud.bigtable.data.v2.models.BulkMutation;
import com.google.cloud.bigtable.data.v2.models.MutateRowsException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.ArrayList;
import java.util.List;
import java.util.logging.Level;
import java.util.logging.Logger;

public class SidecarServiceImpl extends SidecarServiceGrpc.SidecarServiceImplBase {
    private static final Logger logger = Logger.getLogger(SidecarServiceImpl.class.getName());

    private final ConcurrentHashMap<String, BigtableDataClient> clients = new ConcurrentHashMap<>();
    private final String defaultProject;
    private final String defaultInstance;
    private final AtomicLong readRowsCount = new AtomicLong(0);

    private static final Pattern TABLE_NAME_PATTERN = Pattern.compile("projects/([^/]+)/instances/([^/]+)/tables/([^/]+)");

    public SidecarServiceImpl(String project, String instance) {
        this.defaultProject = project;
        this.defaultInstance = instance;
    }

    private BigtableDataClient getClient(String tableName, String appProfileId) throws IOException {
        Matcher matcher = TABLE_NAME_PATTERN.matcher(tableName);
        String project = defaultProject;
        String instance = defaultInstance;

        if (matcher.matches()) {
            project = matcher.group(1);
            instance = matcher.group(2);
        }

        if (project == null || instance == null) {
            throw new RuntimeException("Project and Instance IDs must be provided in table name or during sidecar startup.");
        }

        String clientKey = project + "/" + instance + "/" + (appProfileId == null ? "" : appProfileId);
        BigtableDataClient client = clients.get(clientKey);
        if (client == null) {
            logger.info("Java Sidecar: Initializing new client for " + clientKey);
            logger.info("Java Sidecar: VERIFICATION_RUN_001");
            BigtableDataSettings.Builder settingsBuilder = BigtableDataSettings.newBuilder()
                    .setProjectId(project)
                    .setInstanceId(instance);
            
            if (appProfileId != null && !appProfileId.isEmpty()) {
                settingsBuilder.setAppProfileId(appProfileId);
            }
            
            // Log the value of CBT_ENABLE_DIRECTPATH to verify it's set in the Java process environment
            String directPathEnv = System.getenv("CBT_ENABLE_DIRECTPATH");
            logger.info("Java Sidecar: CBT_ENABLE_DIRECTPATH is currently set to: '" + directPathEnv + "'");
            
            // NOTE: We rely entirely on CBT_ENABLE_DIRECTPATH=true to engage DirectPath.
            // Avoid explicitly setting the endpoint or TransportChannelProvider so we don't interfere with the library defaults.
            
            // NOTE: We don't need to manually configure InstantiatingGrpcChannelProvider here
            // BigtableDataSettings properly configures DirectPath if CBT_ENABLE_DIRECTPATH=true is set in env
            
            BigtableDataSettings settings = settingsBuilder.build();
            logger.info("Java Sidecar: BigtableDataClient created for " + project + "/" + instance);
            client = BigtableDataClient.create(settings);
            BigtableDataClient existing = clients.putIfAbsent(clientKey, client);
            if (existing != null) {
                client.close();
                client = existing;
            }
        }
        return client;
    }

    @Override
    public void ping(PingRequest request, StreamObserver<PingResponse> responseObserver) {
        String message = request.getMessage();
        PingResponse response = PingResponse.newBuilder()
            .setMessage("Pong: " + message)
            .build();
        responseObserver.onNext(response);
        responseObserver.onCompleted();
    }

    @Override
    public void getStats(StatsRequest request, StreamObserver<StatsResponse> responseObserver) {
        StatsResponse response = StatsResponse.newBuilder()
            .setReadRowsCount(readRowsCount.get())
            .build();
        responseObserver.onNext(response);
        responseObserver.onCompleted();
    }

    @Override
    public void readRows(com.example.sidecar.ReadRowsRequest request, StreamObserver<SidecarRow> responseObserver) {
        try {
            readRowsCount.incrementAndGet();
            logger.fine("Java Sidecar: Received readRows call. Request bytes size: " + request.getRequestBytes().size());
            
            // 1. Parse the serialized native ReadRowsRequest bytes
            ReadRowsRequest nativeRequest = ReadRowsRequest.parseFrom(request.getRequestBytes());
            String tableName = nativeRequest.getTableName();
            
            logger.fine("Java Sidecar: Processing full ReadRowsRequest for [" + tableName + "]");

            // 2. Get the appropriate client for this project/instance/appProfile (parsed from request)
            String appProfileId = nativeRequest.getAppProfileId();
            BigtableDataClient dataClient = getClient(tableName, appProfileId);
            
            // 3. Convert the native proto request into a high-level Veneer Query object
            logger.fine("Java Sidecar: Converting proto to Query...");
            Query query = Query.fromProto(nativeRequest);
            logger.fine("Java Sidecar: Query conversion successful.");

            // 4. Execute the query and stream results
            int rowCount = 0;
            for (Row row : dataClient.readRows(query)) {
                rowCount++;
                SidecarRow.Builder rowBuilder = SidecarRow.newBuilder()
                        .setKey(row.getKey());

                for (com.google.cloud.bigtable.data.v2.models.RowCell cell : row.getCells()) {
                    String familyName = cell.getFamily();
                    SidecarFamily.Builder familyBuilder = null;
                    
                    // Find or create family
                    for (SidecarFamily.Builder fb : rowBuilder.getFamiliesBuilderList()) {
                        if (fb.getName().equals(familyName)) {
                            familyBuilder = fb;
                            break;
                        }
                    }
                    if (familyBuilder == null) {
                        familyBuilder = rowBuilder.addFamiliesBuilder().setName(familyName);
                    }

                    ByteString qualifier = cell.getQualifier();
                    SidecarColumn.Builder columnBuilder = null;
                    
                    // Find or create column
                    for (SidecarColumn.Builder cb : familyBuilder.getColumnsBuilderList()) {
                        if (cb.getQualifier().equals(qualifier)) {
                            columnBuilder = cb;
                            break;
                        }
                    }
                    if (columnBuilder == null) {
                        columnBuilder = familyBuilder.addColumnsBuilder().setQualifier(qualifier);
                    }

                    columnBuilder.addCells(SidecarCell.newBuilder()
                            .setValue(cell.getValue())
                            .setTimestampMicros(cell.getTimestamp())
                            .addAllLabels(cell.getLabels())
                            .build());
                }
                responseObserver.onNext(rowBuilder.build());
            }
            logger.fine("Java Sidecar: Finished streaming " + rowCount + " rows.");
            responseObserver.onCompleted();
        } catch (Exception e) {
            logger.log(Level.SEVERE, "Java Sidecar ERROR: " + e.getMessage(), e);
            responseObserver.onError(e);
        }
    }

    @Override
    public void mutateRow(com.example.sidecar.MutateRowRequest request, StreamObserver<com.example.sidecar.MutateRowResponse> responseObserver) {
        try {
            logger.fine("Java Sidecar: Received mutateRow call.");
            MutateRowRequest nativeRequest = MutateRowRequest.parseFrom(request.getRequestBytes());
            String tableName = nativeRequest.getTableName();
            String appProfileId = nativeRequest.getAppProfileId();
            BigtableDataClient dataClient = getClient(tableName, appProfileId);

            RowMutation rowMutation = RowMutation.fromProto(nativeRequest);
            dataClient.mutateRow(rowMutation);

            responseObserver.onNext(com.example.sidecar.MutateRowResponse.newBuilder().build());
            responseObserver.onCompleted();
        } catch (Exception e) {
            logger.log(Level.SEVERE, "Java Sidecar ERROR: " + e.getMessage(), e);
            responseObserver.onError(e);
        }
    }

    @Override
    public void mutateRows(com.example.sidecar.MutateRowsRequest request, StreamObserver<com.example.sidecar.MutateRowsResponse> responseObserver) {
        try {
            logger.fine("Java Sidecar: Received mutateRows call.");
            MutateRowsRequest nativeRequest = MutateRowsRequest.parseFrom(request.getRequestBytes());
            String tableName = nativeRequest.getTableName();
            String appProfileId = nativeRequest.getAppProfileId();
            BigtableDataClient dataClient = getClient(tableName, appProfileId);

            BulkMutation bulkMutation = BulkMutation.fromProto(nativeRequest);

            com.example.sidecar.MutateRowsResponse.Builder responseBuilder = com.example.sidecar.MutateRowsResponse.newBuilder();

            try {
                dataClient.bulkMutateRows(bulkMutation);
                // All succeeded or were retried successfully
                for (int i = 0; i < nativeRequest.getEntriesCount(); i++) {
                    responseBuilder.addEntries(com.example.sidecar.MutateRowsEntry.newBuilder()
                            .setIndex(i)
                            .setStatusCode(0) // OK
                            .build());
                }
            } catch (MutateRowsException e) {
                logger.fine("Java Sidecar: bulkMutateRows had some failures.");
                // Initialize all as OK first
                for (int i = 0; i < nativeRequest.getEntriesCount(); i++) {
                    responseBuilder.addEntries(com.example.sidecar.MutateRowsEntry.newBuilder()
                            .setIndex(i)
                            .setStatusCode(0)
                            .build());
                }

                for (MutateRowsException.FailedMutation failed : e.getFailedMutations()) {
                    int index = (int) failed.getIndex();
                    responseBuilder.setEntries(index, com.example.sidecar.MutateRowsEntry.newBuilder()
                            .setIndex(index)
                            .setStatusCode(failed.getError().getStatusCode().getCode().ordinal())
                            .setStatusMessage(failed.getError().getMessage())
                            .build());
                }
            }

            responseObserver.onNext(responseBuilder.build());
            responseObserver.onCompleted();
        } catch (Exception e) {
            logger.log(Level.SEVERE, "Java Sidecar ERROR: " + e.getMessage(), e);
            responseObserver.onError(e);
        }
    }
}
