require 'google/cloud/bigtable'

ENV['CBT_ENABLE_DIRECTPATH'] = 'true'
ENV['BIGTABLE_TEST_PROJECT'] = 'autonomous-mote-782'
ENV['BIGTABLE_TEST_INSTANCE'] = 'autopilot-rm-test'

puts "Ruby Client: VERIFICATION_RUN_001"
bigtable = Google::Cloud::Bigtable.new project_id: ENV['BIGTABLE_TEST_PROJECT'], use_sidecar: true
table = bigtable.table ENV['BIGTABLE_TEST_INSTANCE'], 'table-10g'

300.times do |i|
  puts "Reading #{i}..."
  table.read_rows(limit: 1).to_a
  sleep 1
end
