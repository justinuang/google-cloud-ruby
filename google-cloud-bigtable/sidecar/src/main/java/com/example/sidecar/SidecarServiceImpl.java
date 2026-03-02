package com.example.sidecar;

import io.grpc.stub.StreamObserver;
import java.util.logging.Logger;
import com.codahale.metrics.Snapshot;

public class SidecarServiceImpl extends SidecarServiceGrpc.SidecarServiceImplBase {
    private static final Logger logger = Logger.getLogger(SidecarServiceImpl.class.getName());

    public SidecarServiceImpl() {
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
    public void clearStats(com.example.sidecar.ClearStatsRequest request, StreamObserver<com.example.sidecar.ClearStatsResponse> responseObserver) {
        SidecarMetrics.getInstance().clear();
        responseObserver.onNext(com.example.sidecar.ClearStatsResponse.newBuilder().build());
        responseObserver.onCompleted();
    }

    @Override
    public void getStats(StatsRequest request, StreamObserver<StatsResponse> responseObserver) {
        Snapshot snapshot = SidecarMetrics.getInstance().getHistogram().getSnapshot();
        double p50 = 0.0, p90 = 0.0, p99 = 0.0, avg = 0.0;
        
        long totalOps = SidecarMetrics.getInstance().getCount();
        if (totalOps > 0) {
            p50 = snapshot.getMedian() / 1_000_000.0;
            p90 = snapshot.getValue(0.90) / 1_000_000.0;
            p99 = snapshot.get99thPercentile() / 1_000_000.0;
            avg = (SidecarMetrics.getInstance().getSumNs() / (double) totalOps) / 1_000_000.0;
        }

        StatsResponse response = StatsResponse.newBuilder()
                .setReadRowsCount(totalOps)
            .setP50Latency(p50)
            .setP90Latency(p90)
            .setP99Latency(p99)
            .setAverageLatency(avg)
            .build();
            
        responseObserver.onNext(response);
        responseObserver.onCompleted();
    }
}
