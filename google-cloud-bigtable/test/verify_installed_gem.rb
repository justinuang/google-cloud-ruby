require "google/cloud/bigtable"

puts ">>> STARTING VERIFICATION USING INSTALLED GEM..."

begin
  bigtable = Google::Cloud::Bigtable.new(
    project_id: "autonomous-mote-782"
  )
  
  # Trigger sidecar and read
  puts ">>> INITIATING SIDECAR READ..."
  # The sidecar will print to stdout/stderr
  bigtable.sidecar_read
  
rescue => e
  puts ">>> VERIFICATION FAILED: #{e.message}"
  puts e.backtrace
  exit 1
end

puts ">>> VERIFICATION SUCCESSFUL!"
