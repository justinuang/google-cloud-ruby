#!/usr/bin/env ruby

require 'google/cloud/bigtable'
require 'optparse'
require 'logger'
require 'digest'

class ZipfianGenerator
  def initialize(min, max, zipfian_constant = 0.99)
    @min = min
    @max = max
    @items = max - min + 1
    @zipfian_constant = zipfian_constant
    @alpha = 1.0 / (1.0 - zipfian_constant)
    @zetan = zeta(@items)
    @eta = (1.0 - (2.0 / @items)**(1.0 - zipfian_constant)) / (1.0 - zeta(2) / @zetan)
  end

  def next_val
    u = rand
    uz = u * @zetan
    if uz < 1.0
      return @min
    end
    if uz < 1.0 + (0.5**@zipfian_constant)
      return @min + 1
    end
    @min + (@items * (@eta * u - @eta + 1.0)**@alpha).to_i
  end

  private

  def zeta(n)
    sum = 0.0
    (1..n).each do |i|
      sum += 1.0 / (i**@zipfian_constant)
    end
    sum
  end
end

options = {
  use_sidecar: false,
  app_profile_id: 'default',
  threads: 50,
  qps: 1000,
  duration: 300,
  warmup: 30,
  project_id: ENV['BIGTABLE_TEST_PROJECT'] || 'autonomous-mote-782',
  instance_id: ENV['BIGTABLE_TEST_INSTANCE'] || 'ju-ruby-sidecar',
  table_id: 'ycsb-100gb',
  recordcount: 100_000_000,
  distribution: 'zipfian'
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
  opts.on("--recordcount N", Integer, "Total records in dataset") do |n|
    options[:recordcount] = n
  end
  opts.on("--distribution TYPE", "Data distribution (zipfian or uniform)") do |type|
    options[:distribution] = type
  end
  opts.on("--table-id ID", "Target Table ID") do |id|
    options[:table_id] = id
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

puts "Initializing Zipfian generator for #{options[:recordcount]} items..."
if options[:distribution] == 'zipfian'
  key_generator = ZipfianGenerator.new(0, options[:recordcount] - 1)
else
  # Default fallback if random or uniform
  key_generator = -> { rand(options[:recordcount]) }
end
puts "Generator Ready."

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
      
      # Workload C: 100% Read Point Lookup (Zipfian distributed)
      begin
        logical_index = options[:distribution] == 'zipfian' ? key_generator.next_val : key_generator.call
        logical_key = sprintf("user%09d", logical_index)
        hash = Digest::MD5.hexdigest(logical_key)[0..7] 
        row_key = "user#{hash}-#{logical_key}"
        
        row = table.read_row(row_key)
        # Force evaluation to ensure data is fetched
        row.cells.first if row
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
