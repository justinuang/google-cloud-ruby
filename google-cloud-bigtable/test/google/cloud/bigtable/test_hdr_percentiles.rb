require "minitest/autorun"
require "HDRHistogram"

class TestMetricsPercentiles < Minitest::Test
  def test_hdr_accuracy
    # 1 to 120_000 ms, 3 sig figs
    histogram = HDRHistogram.new(1, 120_000, 3)
    
    # Push 1 to 100 to represent latencies 1ms to 100ms
    (1..100).each do |i|
      histogram.record(i)
    end
    
    # 50th percentile of 1..100 should be exactly 50
    p50 = histogram.percentile(50.0)
    assert_in_delta 50.0, p50, 1.0, "Expected p50 to be close to 50"
    
    # 90th percentile should be exactly 90
    p90 = histogram.percentile(90.0)
    assert_in_delta 90.0, p90, 1.0, "Expected p90 to be close to 90"

    # 99th percentile should be exactly 99
    p99 = histogram.percentile(99.0)
    assert_in_delta 99.0, p99, 1.0, "Expected p99 to be close to 99"
  end

  def test_hdr_heavy_hitter_distribution
    histogram = HDRHistogram.new(1, 120_000, 3)
    
    # Push 900 fast requests (1ms) and 100 slow requests (100ms)
    900.times { histogram.record(1) }
    100.times { histogram.record(100) }
    
    p50 = histogram.percentile(50.0)
    p90 = histogram.percentile(90.0)
    p99 = histogram.percentile(99.0)
    
    assert_in_delta 1.0, p50, 0.5, "Expected p50 to be 1ms"
    assert_in_delta 1.0, p90, 0.5, "Expected p90 to be 1ms"
    assert_in_delta 100.0, p99, 0.5, "Expected p99 to be 100ms"
  end
end
