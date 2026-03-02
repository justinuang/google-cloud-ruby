package com.example.sidecar;

import com.codahale.metrics.ExponentiallyDecayingReservoir;
import com.codahale.metrics.Histogram;
import com.codahale.metrics.Snapshot;
import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class MetricsPercentilesTest {

    @Test
    public void testDropwizardHistogramAccuracy() {
        Histogram histogram = new Histogram(new ExponentiallyDecayingReservoir());
        
        // Push 1 to 1000 to represent latencies
        for (int i = 1; i <= 1000; i++) {
            histogram.update(i);
        }
        
        Snapshot snapshot = histogram.getSnapshot();
        
        // With 1000 samples, the default reservoir (size 1028) stores all of them exactly.
        assertEquals(500.5, snapshot.getMedian(), 2.0);
        assertEquals(900.0, snapshot.getValue(0.90), 2.0);
        assertEquals(990.0, snapshot.get99thPercentile(), 2.0);
    }
    
    @Test
    public void testDropwizardHeavyHitterDistribution() {
        Histogram histogram = new Histogram(new ExponentiallyDecayingReservoir());
        
        // Push 9000 fast requests (1ms) and 1000 slow requests (100ms)
        for (int i = 0; i < 9000; i++) {
            histogram.update(1);
        }
        for (int i = 0; i < 1000; i++) {
            histogram.update(100);
        }
        
        Snapshot snapshot = histogram.getSnapshot();
        
        // Since we are pushing 10k items, the ExponentiallyDecayingReservoir will randomly sample them down to 1028.
        // It should still correctly represent the distribution bounds over time.
        assertEquals(1.0, snapshot.getMedian(), 0.5);
        assertEquals(100.0, snapshot.get99thPercentile(), 0.5);
    }
}
