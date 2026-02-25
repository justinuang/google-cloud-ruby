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

public class SidecarServiceImpl extends SidecarServiceGrpc.SidecarServiceImplBase {
    private final ConcurrentHashMap<String, BigtableDataClient> clients = new ConcurrentHashMap<>();
    private final String defaultProject;
    private final String defaultInstance;

    private static final Pattern TABLE_NAME_PATTERN = Pattern.compile("projects/([^/]+)/instances/([^/]+)/tables/([^/]+)");

    public SidecarServiceImpl(String project, String instance) {
        this.defaultProject = project;
        this.defaultInstance = instance;
    }

    private BigtableDataClient getClient(String tableName) throws IOException {
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

        String clientKey = project + "/" + instance;
        BigtableDataClient client = clients.get(clientKey);
        if (client == null) {
            System.err.println("Java Sidecar: Initializing new client for " + clientKey);
            BigtableDataSettings settings = BigtableDataSettings.newBuilder()
                    .setProjectId(project)
                    .setInstanceId(instance)
                    .build();
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
    public void readRows(ReadRowsRequest request, StreamObserver<SidecarRow> responseObserver) {
        String tableName = request.getTableName();
        int limit = request.getLimit() > 0 ? request.getLimit() : 1;

        System.err.println("Java Sidecar: Reading rows from " + tableName + " (limit: " + limit + ")");

        try {
            BigtableDataClient dataClient = getClient(tableName);
            
            // Extract tableId from tableName if it's a full path
            String tableId = tableName;
            Matcher matcher = TABLE_NAME_PATTERN.matcher(tableName);
            if (matcher.matches()) {
                tableId = matcher.group(3);
            }

            Query query = Query.create(tableId).limit(limit);
            for (Row row : dataClient.readRows(query)) {
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
            responseObserver.onCompleted();
        } catch (Exception e) {
            System.err.println("Java Sidecar: Error reading rows: " + e.getMessage());
            responseObserver.onError(e);
        }
    }
}
