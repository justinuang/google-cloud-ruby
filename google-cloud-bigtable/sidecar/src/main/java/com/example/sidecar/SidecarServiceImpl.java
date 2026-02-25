package com.example.sidecar;

import com.google.cloud.bigtable.data.v2.BigtableDataClient;
import com.google.cloud.bigtable.data.v2.BigtableDataSettings;
import com.google.cloud.bigtable.data.v2.models.Query;
import com.google.cloud.bigtable.data.v2.models.Row;
import com.google.cloud.bigtable.data.v2.models.RowCell;
import com.google.protobuf.ByteString;
import io.grpc.stub.StreamObserver;
import java.io.IOException;

public class SidecarServiceImpl extends SidecarServiceGrpc.SidecarServiceImplBase {
    private final BigtableDataClient dataClient;

    public SidecarServiceImpl(String project, String instance) throws IOException {
        if (project != null && instance != null) {
            BigtableDataSettings settings = BigtableDataSettings.newBuilder()
                    .setProjectId(project)
                    .setInstanceId(instance)
                    .build();
            this.dataClient = BigtableDataClient.create(settings);
        } else {
            this.dataClient = null;
        }
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
        if (dataClient == null) {
            responseObserver.onError(new RuntimeException("BigtableDataClient not initialized. Provide project and instance."));
            return;
        }

        String tableId = request.getTableId();
        int limit = request.getLimit() > 0 ? request.getLimit() : 1;

        System.err.println("Java Sidecar: Reading rows from " + tableId + " (limit: " + limit + ")");

        try {
            Query query = Query.create(tableId).limit(limit);
            for (Row row : dataClient.readRows(query)) {
                SidecarRow.Builder rowBuilder = SidecarRow.newBuilder()
                        .setKey(row.getKey());

                for (com.google.cloud.bigtable.data.v2.models.RowCell cell : row.getCells()) {
                    // This is a simplified mapping for now. 
                    // We need to group by family and qualifier as per SidecarRow structure.
                    // For the initial "fake" implementation, let's just group them minimally.
                    
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
