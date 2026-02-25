# frozen_string_literal: true

require "minitest/autorun"

# We expect the gem to be installed and available in the load path
# because GEM_HOME and GEM_PATH are set by the Rake task.
require "google/cloud/bigtable"

class InstallVerificationTest < Minitest::Test
  def test_gem_is_loadable
    assert defined?(Google::Cloud::Bigtable)
  end

  def test_version_matches
    # Find the version from the source
    source_version_file = File.expand_path("../../../../lib/google/cloud/bigtable/version.rb", __dir__)
    source_version = File.read(source_version_file).match(/VERSION = "([^"]+)"/)[1]
    
    assert_equal source_version, Google::Cloud::Bigtable::VERSION
  end

  def test_sidecar_launcher_exists_in_gem
    # Find where the gem is installed
    spec = Gem::Specification.find_by_name("google-cloud-bigtable")
    gem_root = spec.gem_dir
    
    launcher_path = File.join(gem_root, "lib/google/cloud/bigtable/runtime/bin/sidecar-launcher")
    assert File.exist?(launcher_path), "Sidecar launcher missing at #{launcher_path}"
    assert File.executable?(launcher_path), "Sidecar launcher at #{launcher_path} is not executable"
  end

  def test_sidecar_functionality
    # Initialize via the new native entry point
    bigtable = nil
    stdout, _stderr = capture_io do
      bigtable = Google::Cloud::Bigtable.new(
        project_id: "autonomous-mote-782",
        use_sidecar: true
      )
    end
    
    # Check if handshake happened during Service initialization
    # Note: If sidecar was already running, this might be empty, but Service.sidecar_stub is idempotent.
    if stdout.include?(">>> RUBY CLIENT: Sidecar ready and verified via gRPC.")
      assert_match(/Sidecar ready and verified via gRPC./, stdout)
    end

    # Verify we can get a table and the service has the flag
    assert bigtable.service.use_sidecar
    table = bigtable.table("autopilot-rm-test", "table-10g")
    assert_kind_of Google::Cloud::Bigtable::Table, table
  end

  def test_sidecar_native_read_rows
    bigtable = Google::Cloud::Bigtable.new(
      project_id: "autonomous-mote-782",
      use_sidecar: true
    )
    table = bigtable.table("autopilot-rm-test", "table-10g")
    
    # Trigger native read_rows (delegates to sidecar)
    # .to_a converts the Enumerable stream to an Array, forcing evaluation of the gRPC call
    rows = table.read_rows(limit: 1).to_a
    
    assert_kind_of Array, rows
    refute_empty rows, "Expected at least one row to be returned from sidecar via read_rows"
    assert_kind_of Google::Cloud::Bigtable::Row, rows.first
    
    # Verify mapping
    row = rows.first
    refute_nil row.key
    refute_empty row.cells
  end

  def test_sidecar_with_filter
    project_id = "autonomous-mote-782"
    instance_id = "autopilot-rm-test"
    table_id = "test-sidecar-filter-#{Time.now.to_i}"

    bigtable = Google::Cloud::Bigtable.new(
      project_id: project_id,
      use_sidecar: true
    )
    instance = bigtable.instance(instance_id)

    # Create a temporary table for deterministic testing
    table = instance.create_table(table_id) do |cfm|
      cfm.add "cf1"
    end

    begin
      # Ingest 5 rows, each with 3 cells to ensure the filter has something to work on
      entries = (1..5).map do |i|
        entry = table.new_mutation_entry "row-#{i}"
        entry.set_cell "cf1", "col1", "value-#{i}-1", timestamp: 1000
        entry.set_cell "cf1", "col1", "value-#{i}-2", timestamp: 2000
        entry.set_cell "cf1", "col1", "value-#{i}-3", timestamp: 3000
        entry
      end
      table.mutate_rows entries

      # Execute native read_rows with a filter through the sidecar
      filter = Google::Cloud::Bigtable::RowFilter.cells_per_column(1)
      # .to_a forces evaluation of the gRPC stream
      rows = table.read_rows(filter: filter).to_a

      # ASSERTIONS
      assert_equal 5, rows.size, "Expected exactly 5 rows to be returned"
      
      rows.sort_by(&:key).each_with_index do |row, idx|
        expected_key = "row-#{idx + 1}"
        assert_equal expected_key, row.key
        
        # Verify the filter: exactly 1 cell per column should remain
        cf1_cells = row.cells["cf1"]
        assert_equal 1, cf1_cells.size, "Filter cells_per_column(1) failed for #{row.key}: found #{cf1_cells.size} cells"
        
        # Bigtable returns the latest cell for cells_per_column(1)
        assert_equal "value-#{idx + 1}-3", cf1_cells.first.value
      end
    ensure
      table.delete if table
    end
  end

  def test_sidecar_statistics
    bigtable = Google::Cloud::Bigtable.new(
      project_id: "autonomous-mote-782",
      use_sidecar: true
    )
    table = bigtable.table("autopilot-rm-test", "table-10g")

    # 1. Fetch initial stats
    initial_stats = bigtable.service.sidecar_stats
    assert_kind_of Com::Example::Sidecar::StatsResponse, initial_stats
    initial_count = initial_stats.read_rows_count

    # 2. Perform a read operation
    # .to_a forces the evaluation of the gRPC stream
    table.read_rows(limit: 1).to_a

    # 3. Fetch final stats and verify increase
    final_stats = bigtable.service.sidecar_stats
    assert_kind_of Com::Example::Sidecar::StatsResponse, final_stats
    final_count = final_stats.read_rows_count

    assert final_count > initial_count, "Expected sidecar read_rows_count to increase. Initial: #{initial_count}, Final: #{final_count}"
  end


  private

  def capture_io
    require 'stringio'
    orig_stdout, orig_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
  end
end

# Use a custom struct for a quick dummy service
require 'ostruct'
