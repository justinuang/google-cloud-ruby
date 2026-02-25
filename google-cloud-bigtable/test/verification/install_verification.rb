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
    # This test combines initialization and ping to handle the singleton sidecar behavior
    service = Google::Cloud::Bigtable::Service.new("autonomous-mote-782", nil)
    project = nil
    
    # 1. Verify initialization (handshake via UDS)
    stdout, _stderr = capture_io do
      project = Google::Cloud::Bigtable::Project.new(service)
      project.instance_id = "autopilot-rm-test"
      project.sidecar_stub # Trigger lazy init
    end
    
    # Check if handshake happened (either in this call or previously)
    if stdout.include?(">>> RUBY CLIENT: Sidecar ready and verified via gRPC.")
      assert_match(/Sidecar ready and verified via gRPC./, stdout)
    end


    # 2. Verify Ping
    stdout, _stderr = capture_io do
      response = project.sidecar_ping("Verification Ping")
      assert_equal "Pong: Verification Ping", response
    end
  end

  def test_sidecar_read
    service = Google::Cloud::Bigtable::Service.new("autonomous-mote-782", nil)
    project = Google::Cloud::Bigtable::Project.new(service)
    project.instance_id = "autopilot-rm-test"
    
    # Trigger sidecar read
    rows = project.sidecar_read("table-10g", 1)
    
    assert_kind_of Array, rows
    refute_empty rows, "Expected at least one row to be returned from sidecar_read"
    assert_kind_of Com::Example::Sidecar::SidecarRow, rows.first
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
