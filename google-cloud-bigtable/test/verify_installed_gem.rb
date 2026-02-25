STDOUT.sync = true
require "google/cloud/bigtable"

puts ">>> STARTING VERIFICATION USING INSTALLED GEM..."

begin
  bigtable = Google::Cloud::Bigtable.new(
    project_id: "autonomous-mote-782"
  )
  bigtable.instance_id = "autopilot-rm-test"
  
  # Trigger sidecar and read
  puts ">>> INITIATING SIDECAR READ..."
  rows = bigtable.sidecar_read("table-10g")
  
  puts ">>> RUBY CLIENT: Received #{rows.size} rows"
  rows.each do |row|
    puts ">>> ROW KEY: #{row.key}"
    row.families.each do |family|
      puts "  FAMILY: #{family.name}"
    end
  end

  if rows.empty?
    raise ">>> VERIFICATION FAILED: No rows returned from sidecar_read"
  end
  
rescue => e
  puts ">>> VERIFICATION FAILED: #{e.message}"
  puts e.backtrace
  exit 1
end

puts ">>> VERIFICATION SUCCESSFUL!"
