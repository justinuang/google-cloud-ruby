# frozen_string_literal: true

require "minitest/autorun"
require "google/cloud/bigtable"

class NativeTimestampVerificationTest < Minitest::Test
  def setup
    @project_id = "autonomous-mote-782"
    @instance_id = "autopilot-rm-test"
    @table_id = "test-native-ts-#{Time.now.to_i}"

    # Explicitly disable sidecar to verify native behavior
    @bigtable = Google::Cloud::Bigtable.new(
      project_id: @project_id,
      use_sidecar: false
    )
    @instance = @bigtable.instance(@instance_id)
    @table = @instance.create_table(@table_id) do |cfm|
      cfm.add "cf1"
    end
  end

  def teardown
    @table.delete if @table
  end

  def test_timestamp_0_behavior
    row_key = "row-default-ts"
    entry = @table.new_mutation_entry row_key
    # No timestamp specified
    entry.set_cell "cf1", "col1", "value-0"
    @table.mutate_row entry

    # Verify via Read
    rows = @table.read_rows(keys: [row_key]).to_a
    assert_equal 1, rows.size
    cell = rows.first.cells["cf1"].first
    
    puts "\n[Ruby Native] Row: #{row_key}, Timestamp: #{cell.timestamp}"
    assert_equal 0, cell.timestamp, "Expected native Ruby to default to timestamp 0"

    # Verify via CBT
    cbt_output = `cbt -project #{@project_id} -instance #{@instance_id} lookup #{@table_id} #{row_key}`
    puts "[CBT Ground Truth]\n#{cbt_output}"
    # 1969/12/31-16:00:00.000000 is timestamp 0 in PST (UTC-8)
    # 1970/01/01-00:00:00.000000 would be UTC
    # We'll just check for 1969/12/31 or 1970/01/01
    assert_match /1969\/12\/31|1970\/01\/01/, cbt_output
  end

  def test_server_side_timestamp_behavior
    row_key = "row-server-ts"
    entry = @table.new_mutation_entry row_key
    # Explicit -1 for server-side
    entry.set_cell "cf1", "col1", "value-neg-1", timestamp: -1
    @table.mutate_row entry

    # Verify via Read
    rows = @table.read_rows(keys: [row_key]).to_a
    assert_equal 1, rows.size
    cell = rows.first.cells["cf1"].first
    
    puts "\n[Ruby Native] Row: #{row_key}, Timestamp: #{cell.timestamp}"
    # A reasonably recent timestamp (e.g. within the last 10 minutes)
    ten_minutes_ago_micros = (Time.now.to_i - 600) * 1_000_000
    assert cell.timestamp > ten_minutes_ago_micros, "Expected a recent server-side timestamp, got #{cell.timestamp}"

    # Verify via CBT
    cbt_output = `cbt -project #{@project_id} -instance #{@instance_id} lookup #{@table_id} #{row_key}`
    puts "[CBT Ground Truth]\n#{cbt_output}"
    # CBT prints timestamp in its own format, but we've asserted the numeric value via Ruby read.
    # Just checking that it's NOT 0 in CBT.
    refute_match /timestamp:\s+0/, cbt_output
  end
end
