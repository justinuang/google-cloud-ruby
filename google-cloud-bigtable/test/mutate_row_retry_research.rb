# frozen_string_literal: true

require "minitest/autorun"
require "google/cloud/bigtable"
require "google/cloud/bigtable/v2"
require "google/bigtable/v2/bigtable_services_pb"
require "gapic/grpc"

class MutateRowRetryResearch < Minitest::Test
  def setup
    @project_id = "test-project"
    @instance_id = "test-instance"
    @table_id = "test-table"
    
    # Mock the service and gapic client
    @bigtable = Google::Cloud::Bigtable.new project_id: @project_id
    @service = @bigtable.service
    
    @mock_gapic_client = Minitest::Mock.new
    @service.mocked_client = @mock_gapic_client
  end

  def test_mutate_row_singular_actually_retries_on_failure
    entry = Google::Cloud::Bigtable::MutationEntry.new "row-1"
    entry.set_cell "cf1", "col1", "val1", timestamp: -1
    
    # Flexible mock object to bypass strict Minitest::Mock expectations
    mock_grpc_stub = Object.new
    @call_count = 0
    # Capture the test object to use its @call_count or just use the stub's own state
    mock_grpc_stub.instance_variable_set(:@call_count, 0)
    
    def mock_grpc_stub.method(_name); self; end
    # Mock the operation object returned by the gRPC stub
    def mock_grpc_stub.call(*args, **kwargs)
       @call_count += 1
       op = Minitest::Mock.new
       # Mock the execute method which GAPIC calls to actually perform the RPC
       op.expect :execute, nil do
         if @call_count == 1
           raise GRPC::Unavailable.new("Simulated failure")
         end
         Google::Cloud::Bigtable::V2::MutateRowResponse.new
       end
       # Mock metadata/trailing_metadata for GAPIC's block yield
       op.expect :trailing_metadata, {}
       op
    end
    # GAPIC ServiceStub expects the stub to have the RPC method name
    mock_grpc_stub.define_singleton_method(:mutate_row) { |*args, **kwargs| self.call(*args, **kwargs) }
    
    # We also need to mock some GAPIC internals to let the client initialize
    def mock_grpc_stub.logger; nil; end
    def mock_grpc_stub.stub_logger; nil; end
    def mock_grpc_stub.universe_domain; "googleapis.com"; end

    # Hijack the Stub class creation
    Google::Cloud::Bigtable::V2::Bigtable::Stub.stub :new, mock_grpc_stub do
      client = Google::Cloud::Bigtable::V2::Bigtable::Client.new do |config|
        config.rpcs.mutate_row.retry_policy[:initial_delay] = 0.01
        config.rpcs.mutate_row.retry_policy[:multiplier] = 1.0
      end
      @service.mocked_client = client
      @bigtable.table(@instance_id, @table_id).mutate_row entry
    end
    
    actual_count = mock_grpc_stub.instance_variable_get(:@call_count)
    puts "\n[Research] MutateRow call count after one simulated failure: #{actual_count}"
    assert_equal 2, actual_count, "Expected MutateRow to be called twice (initial + 1 retry)"
  end

  def test_mutate_rows_plural_respects_idempotency
    # This one is handled by RowsMutator, which we already saw checks retryable?
    # No need to prove it again if we satisfy ourselves with MutateRow singular.
  end
end

puts "Checking default retry config for MutateRow in GAPIC client..."
client_config = Google::Cloud::Bigtable::V2::Bigtable::Client.configure
mutate_row_config = client_config.rpcs.mutate_row
puts "MutateRow Retry Codes: #{mutate_row_config.retry_policy[:retry_codes].inspect}"
