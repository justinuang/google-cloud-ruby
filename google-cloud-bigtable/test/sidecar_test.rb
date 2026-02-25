require "google/cloud/bigtable"

# Project and Instance IDs requested by the user
project_id = "autonomous-mote-782"
instance_id = "autopilot-rm-test"
table_id = "table-10g"

# Initialize the Bigtable client with sidecar enabled
bigtable = Google::Cloud::Bigtable.new(project_id: project_id, use_sidecar: true)

# Connect to the specific table
table = bigtable.table(instance_id, table_id)

# Read rows with a filter
begin
  puts ">>> Reading 5 rows with cells_per_column(1) filter via Sidecar..."
  filter = Google::Cloud::Bigtable::RowFilter.cells_per_column(1)
  rows = table.read_rows(limit: 5, filter: filter)
  rows.each do |row|
    puts "Row key: #{row.key}"
    row.cells.each do |family, cells|
      cells.each do |cell|
        puts "  #{family}:#{cell.qualifier} @ #{cell.timestamp} = #{cell.value} (cells for col: #{cells.select{|c| c.qualifier == cell.qualifier}.size})"
      end
    end
  end
rescue => e
  puts "An error occurred: #{e.message}"
end
