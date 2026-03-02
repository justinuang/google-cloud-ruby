require 'csv'

files = {
  "Java Sidecar (DirectPath)" => "benchmark_results/phase_12_8h_c3/benchmark_sidecar_local.log",
  "Java Sidecar (CloudPath)" => "benchmark_results/phase_12_8h_c3/benchmark_sidecar_cloudpath_local.log",
  "Native Ruby (CloudPath)" => "benchmark_results/phase_12_8h_c3/benchmark_ruby_local.log"
}

timeseries = {}
480.times { |i| timeseries[i+1] = {} }

files.each do |target, path|
  current_minute = nil
  File.readlines(path).each do |line|
    if line =~ /^Minute (\d+)/
      current_minute = $1.to_i
    elsif current_minute && line =~ /p99 Latency:\s+([\d\.]+)\s+ms/
      timeseries[current_minute][target] = $1.to_f
      current_minute = nil
    end
  end
end

CSV.open("benchmark_results/phase_12_8h_c3/p99_timeseries.csv", "w") do |csv|
  csv << ["Minute", "Java Sidecar (DirectPath) p99 (ms)", "Java Sidecar (CloudPath) p99 (ms)", "Native Ruby (CloudPath) p99 (ms)"]
  (1..480).each do |minute|
    csv << [minute, timeseries[minute]["Java Sidecar (DirectPath)"], timeseries[minute]["Java Sidecar (CloudPath)"], timeseries[minute]["Native Ruby (CloudPath)"]]
  end
end

puts "Done extracting p99 timeseries to CSV."

# Sample every 30 mins for the mermaid graph
samples = [1, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 360, 390, 420, 450, 480].select { |m| timeseries[m] && timeseries[m]["Java Sidecar (DirectPath)"] }
puts "Mermaid X-axis:"
puts samples.map { |s| "\"M#{s}\"" }.join(", ")

files.keys.each do |target|
  puts "#{target}:"
  puts samples.map { |m| timeseries[m][target] || 0 }.join(", ")
end
