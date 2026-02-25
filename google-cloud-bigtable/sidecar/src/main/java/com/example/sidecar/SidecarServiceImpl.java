package com.example.sidecar;

import io.grpc.stub.StreamObserver;

public class SidecarServiceImpl extends SidecarServiceGrpc.SidecarServiceImplBase {
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
        // Deferred implementation
        responseObserver.onCompleted();
    }
}
