#!/usr/bin/env ruby

require 'google/cloud/bigtable'
require 'optparse'
require 'logger'

options = {
  use_sidecar: false,
  app_profile_id: 'default',
  threads: 50,
  qps: 1000,
  duration: 300,
  warmup: 30,
  project_id: ENV['BIGTABLE_TEST_PROJECT'] || 'autonomous-mote-782',
  instance_id: ENV['BIGTABLE_TEST_INSTANCE'] || 'autopilot-rm-test',
  table_id: 'table-10g'
}

OptionParser.new do |opts|
  opts.banner = "Usage: ycsb_benchmark.rb [options]"

  opts.on("--use-sidecar", "Use the Java sidecar") do
    options[:use_sidecar] = true
  end

  opts.on("--app-profile-id ID", "App profile ID to use") do |id|
    options[:app_profile_id] = id
  end

  opts.on("--threads N", Integer, "Number of threads") do |n|
    options[:threads] = n
  end

  opts.on("--qps N", Integer, "Target total QPS") do |n|
    options[:qps] = n
  end

  opts.on("--duration N", Integer, "Benchmark duration in seconds") do |n|
    options[:duration] = n
  end
end.parse!

puts "Starting YCSB Read-Only Benchmark with:"
puts options.inspect

# Optional: suppress noisy GRPC/client logs via logger if needed
# Google::Cloud::Bigtable.configure do |config|
#   config.logger = Logger.new(nil)
# end

bigtable = Google::Cloud::Bigtable.new(
  project_id: options[:project_id],
  use_sidecar: options[:use_sidecar]
)
table = bigtable.table(options[:instance_id], options[:table_id], app_profile_id: options[:app_profile_id])

qps_per_thread = options[:qps].to_f / options[:threads]
sleep_time_per_query = 1.0 / qps_per_thread

latencies = []
latencies_mutex = Mutex.new

start_time = Time.now
end_time = start_time + options[:duration]
warmup_end = start_time + options[:warmup]

threads = options[:threads].times.map do |i|
  Thread.new do
    loop do
      now = Time.now
      break if now > end_time
      
      req_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      
      # Workload C: 100% Read, limit 1 (equivalent to point lookup or short scan)
      begin
        table.read_rows(limit: 1).to_a
      rescue => e
        abort "Fatal error during benchmark: #{e.message}"
      end
      
      req_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      latency_ms = (req_end - req_start) * 1000.0
      
      # Only record latency if we are past the warmup phase
      if now > warmup_end
        latencies_mutex.synchronize { latencies << latency_ms }
      end
      
      # Rate limit
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - req_start
      sleep_dur = sleep_time_per_query - elapsed
      sleep(sleep_dur) if sleep_dur > 0
    end
  end
end

threads.each(&:join)

puts "========================================"
puts "Benchmark Finished!"
puts "Total operations recorded (post-warmup): #{latencies.size}"

if latencies.empty?
  puts "No latencies recorded. Was the run duration too short?"
else
  sorted = latencies.sort
  puts "Throughput (ops/sec): #{latencies.size.to_f / (options[:duration] - options[:warmup])}"
  puts "Average Latency: #{sorted.sum / sorted.size} ms"
  puts "p50 Latency:     #{sorted[(sorted.size * 0.50).to_i]} ms"
  puts "p90 Latency:     #{sorted[(sorted.size * 0.90).to_i]} ms"
  puts "p99 Latency:     #{sorted[(sorted.size * 0.99).to_i]} ms"
  puts "p99.9 Latency:   #{sorted[(sorted.size * 0.999).to_i]} ms"
end
puts "========================================"
