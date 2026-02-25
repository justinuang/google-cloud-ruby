# Bigtable Java Sidecar Prototype

This prototype provides a way to proxy Bigtable data operations from the Ruby client to a Java-based sidecar. This allows the Ruby client to benefit from the performance and robust features of the Java Bigtable Veneer client (e.g., optimized batching, retries, and gRPC connection management).

## Enabling the Sidecar

The sidecar is currently opt-in. You can enable it by setting the `use_sidecar` configuration in your `Google::Cloud::Bigtable` service or project.

```ruby
bigtable = Google::Cloud::Bigtable.new(use_sidecar: true)
```

## Benefits

- **DirectPath Support**: Enables high-performance, low-latency networking with Bigtable (via the Java client).
- **Performance**: The Java Veneer client is highly optimized for high-throughput reads and writes.
- **Robustness**: Advanced retry logic and error handling are managed by the battle-tested Java client.
- **Connection Management**: Improved handling of gRPC channels and sub-channels.

## Supported Operations

- `read_rows`
- `mutate_row`
- `mutate_rows`

## Caveats and Known Issues

### Idempotency and Server-side Timestamps

> [!WARNING]
> **Risk of Duplicate Data**: The Java Veneer client, which powers the sidecar's mutations, assumes by default that all mutations are idempotent. It enables automatic retries for bulk mutations to ensure high success rates.
>
> If you perform a `mutate_row` or `mutate_rows` operation using **server-side timestamps** (set by passing `timestamp: -1` in Ruby), these mutations are technically non-idempotent. If a network transient error occurs, the Java client might retry the mutation, which could result in **duplicate cells** with different server-assigned timestamps in Bigtable.
>
> **Status**: This behavior diverges from the native Ruby client, which explicitly avoids retrying mutations with server-side timestamps. We are currently investigating ways to synchronize this behavior. Use server-side timestamps with the sidecar only if your application can tolerate potential duplicates.

### Performance Tuning

You can pass arbitrary JVM flags to the sidecar process (e.g., to increase memory) by setting the `BIGTABLE_SIDECAR_JVM_FLAGS` environment variable before the sidecar starts.

```bash
export BIGTABLE_SIDECAR_JVM_FLAGS="-Xmx1g -Xms512m"
```

### Known Warnings

- **SO_KEEPALIVE**: You may see a warning like `WARNING: Unknown channel option 'SO_KEEPALIVE'`. This is a harmless side effect of gRPC attempting to apply standard TCP keep-alive settings to a Unix Domain Socket (UDS) channel. It can be safely ignored.

## Technical Implementation

- **Process Management**: The sidecar runs as a separate process managed by the Ruby client. It is lazily initialized and shared across all threads in a Ruby process.
- **Packaging**: The sidecar is packaged within the Ruby gem itself:
    - **JRE**: A stripped-down, custom Java Runtime Image (created via `jlink`) is included, containing only the necessary modules to run the sidecar. This avoids requiring a full JDK on the user's system.
    - **FAT JAR**: The Java application and all its dependencies (including the Google Cloud Bigtable client and gRPC) are shaded into a single "fat" JAR.
- **Communication**: The Ruby client and Java sidecar communicate over a Unix Domain Socket using gRPC.
- **Data Transfer**: Requests and responses are passed as serialized protobuf bytes for maximum efficiency and to ensure compatibility with the native Bigtable proto definitions.
