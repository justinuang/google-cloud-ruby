require "minitest/autorun"
require "tdigest"

class TestMetricsPercentiles < Minitest::Test
  def test_tdigest_accuracy
    digest = TDigest::TDigest.new
    
    # Push 1 to 100 to represent latencies 1ms to 100ms
    (1..100).each do |i|
      digest.push(i)
    end
    
    # 50th percentile of 1..100 should be around 50
    p50 = digest.percentile(0.50)
    assert_in_delta 50.0, p50, 1.0, "Expected p50 to be close to 50"
    
    # 90th percentile should be around 90
    p90 = digest.percentile(0.90)
    assert_in_delta 90.0, p90, 1.0, "Expected p90 to be close to 90"

    # 99th percentile should be around 99
    p99 = digest.percentile(0.99)
    assert_in_delta 99.0, p99, 1.0, "Expected p99 to be close to 99"
  end

  def test_tdigest_heavy_hitter_distribution
    digest = TDigest::TDigest.new
    
    # Push 900 fast requests (1ms) and 100 slow requests (100ms)
    900.times { digest.push(1) }
    100.times { digest.push(100) }
    
    p50 = digest.percentile(0.50)
    p90 = digest.percentile(0.90)
    p99 = digest.percentile(0.99)
    
    assert_in_delta 1.0, p50, 0.5, "Expected p50 to be 1ms"
    assert_in_delta 100.0, p90, 0.5, "Expected p90 to be 100ms (we have exactly 10% 100ms)"
    assert_in_delta 100.0, p99, 0.5, "Expected p99 to be 100ms"
  end
end
