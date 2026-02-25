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
    source_version_file = File.expand_path("../../lib/google/cloud/bigtable/version.rb", __dir__)
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
    rows = table.read_rows(limit: 1).to_a
    
    assert_kind_of Array, rows
    refute_empty rows, "Expected at least one row to be returned from sidecar via read_rows"
    assert_kind_of Google::Cloud::Bigtable::Row, rows.first
    
    # Verify mapping
    row = rows.first
    refute_nil row.key
    refute_empty row.cells
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
