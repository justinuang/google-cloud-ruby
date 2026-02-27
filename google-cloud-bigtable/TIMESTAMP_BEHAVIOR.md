# Bigtable Timestamp Handling Research

I have investigated how the Google Cloud Bigtable Ruby client handles timestamps, specifically addressing whether it is possible or easy to omit client-side timestamps in favor of server-side ones.

## Key Findings

### 1. Default Behavior: 0 vs. Server-Side
In the Ruby client, if you do not specify a timestamp, it defaults to **0** (the Unix epoch). This is because the underlying Protobuf field `timestamp_micros` defaults to 0 in Proto3, and Bigtable's proto definition specifies that unspecified timestamps default to zero.

**Stored as 0, Read as 0**:
If you write a cell without a timestamp, it is stored in Bigtable with a literal timestamp of `0`. When you read it back, you will see `0`. This is often undesirable as it can lead to immediate deletion if you have an age-based garbage collection policy (TTL).

**Server-Side Now via `-1`**:
To request that the Bigtable server assign the current server time, you must explicitly pass **`-1`**.
```ruby
entry.set_cell "cf", "col", "value", timestamp: -1
```

### 3. Integration Test Results (Ruby Native)
A native integration test (bypassing the sidecar) confirmed the following behavior:

- **Omitted Timestamp**: Writes a cell without a `timestamp` argument.
    - **Ruby Read Result**: `0`
    - **CBT Lookup Result**: `@ 1969/12/31-16:00:00.000000` (Unix Epoch)
    - **Conclusion**: Omitted timestamps in Ruby are permanently stored as literal `0` and do **not** receive server-side time assignments.
- **Explicit Server Timestamp**: Writes a cell with `timestamp: -1`.
    - **Ruby Read Result**: `1772144865518000` (Current microsecond timestamp)
    - **Check**: `-1` successfully triggers Bigtable server-side time assignment.

### 3. Go (Safe by Default)

The Go client (`cloud.google.com/go/bigtable`) is highly conservative and safe regarding retries:

- **Server-Side Trigger**: Uses `bigtable.ServerTime` (constant value `-1`).
- **Idempotency Check**: The client contains a `mutationsAreRetryable` function that scans for `-1`.
- **Singular/Plural Consistency**: Both `Apply` (singular) and `ApplyBulk` (plural) use this check. If a mutation is non-idempotent, the client **disables retries** for that RPC call entirely (for `Apply`) or for that specific row (for `ApplyBulk`).
- **Safety**: Unlike Ruby's singular `mutate_row`, Go protects users from duplicate writes even when using server-side timestamps.

### Comparison Table

| Language | Singular `MutateRow` Retry | Plural `MutateRows` Retry | Mechanism |
| :--- | :--- | :--- | :--- |
| **Ruby** | **Yes** (Unsafe) | **No** (Safe) | GAPIC Default vs `RowsMutator` |
| **Go** | **No** (Safe) | **No** (Safe) | `mutationsAreRetryable` check |
| **C++** | **No** (Safe) | **No** (Safe) | `IdempotentMutationPolicy` |

### Why the difference in Ruby?
The Ruby client implements a sophisticated selective retry mechanism for the streaming `mutate_rows` RPC to ensure correctness for complex batches. However, for the simpler singular `mutate_row` RPC, it relies on the generic GAPIC retry mechanism which is unaware of the specific idempotency implications of Bigtable mutation content.

## Recommendations
1. **Always provide a timestamp** in Ruby if you want idempotency and a non-zero timestamp (e.g., `(Time.now.to_f * 1_000_000).to_i`).
2. Use `timestamp: -1` only if server-side time is strictly required and you have measured the non-idempotent retry implications for your application.

## Usage Examples from Tests

### From `mutation_entry_test.rb`
The tests explicitly verify that omitting the timestamp results in `0`:
```ruby
it "add set cell mutation without timestamp" do
  entry.set_cell(family, qualifier, cell_value)
  _(entry.to_grpc.mutations.first.set_cell.timestamp_micros).must_equal 0
end
```

And verify the server-side behavior makes it non-retryable:
```ruby
it "add set cell non retyable mutation with server time timestamp" do
  entry.set_cell(family, qualifier, cell_value, timestamp: -1)
  _(entry.retryable?).must_equal false
end
```

## Conclusion
The Ruby client **does** allow server-side timestamps via the special value **`-1`**, but it defaults to **`0`** when no timestamp is provided. This differs from Java (idempotent local "now") and Go/C++ (non-idempotent server "now").
