require "google/cloud/bigtable"

ENV["CBT_ENABLE_DIRECTPATH"] = "true"
ENV["BIGTABLE_TEST_PROJECT"] = "autonomous-mote-782"
ENV["BIGTABLE_TEST_INSTANCE"] = "autopilot-rm-test"

puts "Initializing Bigtable with sidecar..."
bigtable = Google::Cloud::Bigtable.new project_id: ENV["BIGTABLE_TEST_PROJECT"], use_sidecar: true
table = bigtable.table ENV["BIGTABLE_TEST_INSTANCE"], "table-10g"

puts "Attempting to read rows through sidecar..."
rows = table.read_rows(limit: 1).to_a
if rows.any?
  puts "Successfully read row: #{rows.first.key}"
else
  puts "No rows found."
end
