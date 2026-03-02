package com.example.sidecar;

import com.codahale.metrics.Histogram;
import com.codahale.metrics.ExponentiallyDecayingReservoir;
import java.util.concurrent.atomic.AtomicLong;

public class SidecarMetrics {
    private static final SidecarMetrics INSTANCE = new SidecarMetrics();

    private final AtomicLong readRowsCount = new AtomicLong(0);
    private final AtomicLong readRowsSumNs = new AtomicLong(0);
    private Histogram readRowsHistogram = new Histogram(new ExponentiallyDecayingReservoir());

    private SidecarMetrics() {}

    public static SidecarMetrics getInstance() {
        return INSTANCE;
    }

    public void recordReadRowsLatency(long latencyNs) {
        readRowsCount.incrementAndGet();
        readRowsSumNs.addAndGet(latencyNs);
        readRowsHistogram.update(latencyNs);
    }

    public void clear() {
        readRowsCount.set(0);
        readRowsSumNs.set(0);
        readRowsHistogram = new Histogram(new ExponentiallyDecayingReservoir());
    }

    public long getCount() {
        return readRowsCount.get();
    }

    public long getSumNs() {
        return readRowsSumNs.get();
    }

    public Histogram getHistogram() {
        return readRowsHistogram;
    }
}
