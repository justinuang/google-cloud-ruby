require 'google/cloud/bigtable'

bigtable = Google::Cloud::Bigtable.new(project_id: 'autonomous-mote-782')
table = bigtable.instance('ju-ruby-sidecar').table('ycsb-1gb')
entry = table.new_mutation_entry('test-row')
entry.set_cell('cf', 'field0', 'test-data', timestamp: (Time.now.to_f * 1_000).to_i)
batch = [entry]

results = table.mutate_rows(batch)
results.each do |r|
  puts "Code: #{r.status.code}, Msg: #{r.status.message}"
end
