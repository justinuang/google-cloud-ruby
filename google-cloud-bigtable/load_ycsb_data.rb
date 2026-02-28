#!/usr/bin/env ruby

require 'google/cloud/bigtable'
require 'securerandom'
require 'optparse'
require 'digest'
require 'thread'

options = {
  project_id: ENV['BIGTABLE_TEST_PROJECT'] || 'autonomous-mote-782',
  instance_id: ENV['BIGTABLE_TEST_INSTANCE'] || 'ju-ruby-sidecar',
  table_id: 'ycsb-1gb',
  recordcount: 1_000_000,
  threads: 32,
  batch_size: 1000
}

OptionParser.new do |opts|
  opts.banner = "Usage: load_ycsb_data.rb [options]"

  opts.on("--recordcount N", Integer, "Total records to load (default: 1,000,000)") do |n|
    options[:recordcount] = n
  end
  opts.on("--threads N", Integer, "Number of threads to use (default: 32)") do |n|
    options[:threads] = n
  end
  opts.on("--batch-size N", Integer, "Number of mutations per MutateRows request (default: 1000)") do |n|
    options[:batch_size] = n
  end
  opts.on("--table-id ID", "Target Table ID (default: ycsb-1gb)") do |id|
    options[:table_id] = id
  end
end.parse!

puts "Starting YCSB Data Load with:"
puts options.inspect

bigtable = Google::Cloud::Bigtable.new(
  project_id: options[:project_id]
)
instance = bigtable.instance(options[:instance_id])

# 1. Create the table if it doesn't exist
table = instance.table(options[:table_id])
unless table.exists?
  puts "Table '#{options[:table_id]}' not found. Creating table and 'cf' column family..."
  instance.create_table(options[:table_id]) do |tc|
    tc.add 'cf'
  end
end
table = instance.table(options[:table_id])

# 2. Worker Thread Setup
records_per_thread = options[:recordcount] / options[:threads]
threads = []
start_time = Time.now

puts "Generating and writing #{options[:recordcount]} records across #{options[:threads]} threads..."
puts "Payload: 1 KB per row (1024 bytes)."

# Generating a constant 1KB string to avoid doing it per-row
PAYLOAD = "A" * 1024 

options[:threads].times do |thread_idx|
  threads << Thread.new do
    start_record = thread_idx * records_per_thread
    end_record = start_record + records_per_thread
    
    current_record = start_record
    
    while current_record < end_record
      batch = []
      batch_end = [current_record + options[:batch_size], end_record].min
      
      while current_record < batch_end
        # Hash the logical key to distribute row keys uniformly
        logical_key = sprintf("user%09d", current_record)
        hash = Digest::MD5.hexdigest(logical_key)[0..7] 
        row_key = "user#{hash}-#{logical_key}"
        
        entry = table.new_mutation_entry(row_key)
        entry.set_cell('cf', 'field0', PAYLOAD)
        batch << entry
        
        current_record += 1
      end
      
      # Execute batch
      begin
        table.mutate_rows(batch)
        if current_record % 10_000 == 0
          puts "[Thread #{thread_idx}] Successfully wrote #{current_record - start_record} / #{records_per_thread} records... (Current Key: #{logical_key})"
        end
      rescue => e
        puts "[Thread #{thread_idx}] Warning: Batch mutation failed: #{e.message}"
        sleep 1 # Backoff
        retry
      end
    end
  end
end

threads.each(&:join)

duration = Time.now - start_time
puts "====================================="
puts "Data load finished in #{duration.round(2)} seconds."
puts "Throughput: #{(options[:recordcount] / duration).round(2)} records/sec."
puts "To verify count, run:"
puts "cbt -project=#{options[:project_id]} -instance=#{options[:instance_id]} count #{options[:table_id]}"
