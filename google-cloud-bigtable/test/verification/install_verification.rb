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

  def test_initialization_finds_sidecar
    # This will trigger setup_java_sidecar in project.rb
    # We mock IO.popen to avoid actually running the Java process if we just want to verify path logic,
    # but here we can actually let it run if the environment permits, or just verify it finds the path.
    
    # For now, let's just create a project and see if it fails early.
    # Note: This might require some credentials or environment settings,
    # but the constructor itself (setup_java_sidecar) is what we want to test.
    
    # We'll use a dummy service object
    service = OpenStruct.new(project_id: "test-project")
    
    # Capture stdout to see the "Located jlink launcher" message
    stdout = capture_io do
      Google::Cloud::Bigtable::Project.new(service)
    end.first
    
    assert_match(/Located jlink launcher in gem/, stdout)
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
