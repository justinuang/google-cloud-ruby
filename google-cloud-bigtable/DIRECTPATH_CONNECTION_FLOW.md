# Bigtable DirectPath Connection Flow & Failure Dissection

This document analyzes the Google Cloud Bigtable DirectPath client connection flow, specifically detailing why forcing the Java Virtual Machine (JVM) to use an IPv4 stack (`-Djava.net.preferIPv4Stack=true`) breaks DirectPath and forces a silent fallback to CloudPath (GFE/CFE).

## The Standard DirectPath Connection Flow

When `CBT_ENABLE_DIRECTPATH=true` is provided to the Java gRPC Bigtable client, the following sequence of events occurs:

1. **Resolver Initialization**: The `grpc-java` library delegates DNS and endpoint resolution to the `xds` (xDiscovery Service) resolver rather than standard DNS.
2. **Control Plane Handshake**: The `xds` client bootstraps and establishes a connection to the Traffic Director control plane (`directpath-pa.googleapis.com` or `traffic-director-c2p.xds.googleapis.com`).
3. **Endpoint Discovery**: The control plane returns physical backend server endpoints for the specific Bigtable instance (`bigtable.googleapis.com`).
4. **IPv6 Exclusivity**: Crucially, internal Google infrastructure, particularly the backend servers that power Bigtable storage nodes, operate *exclusively* within Google's internal **IPv6 address space** (e.g., `[2001:4860:8040:147:0:56a:af15:ef5f]:25441`). 
5. **ALTS Negotiation**: The gRPC client opens a physical TCP socket to the provided IPv6 backend address and performs ALTS (Application Layer Transport Security) handshake to mutually authenticate over Google's internal network.
6. **Direct Data Transfer**: Once connected, all data flows directly from the VM to the Bigtable backend, entirely bypassing the external Google Cloud network edge (CFE/GFE).

## The Breakage: `preferIPv4Stack`

In the original Ruby Sidecar prototype, the `service.rb` script spawned the Java JVM with the following arguments:
```bash
java -Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true -cp ...
```

This introduced a fatal constraint into the connection flow.

1. The `xds` resolver successfully contacts the control plane and receives the list of internal backend endpoints.
2. Crucially, because Google's internal DirectPath fabric for storage nodes operates exclusively on IPv6, **the xDS control plane only returns IPv6 addresses** for these backends. There are no IPv4 addresses allocated for the internal direct connection.
3. When `grpc-java` (via Netty) iterates through the list of xDS endpoints and attempts a `connect()` system call to any of the provided IPv6 backend addresses, the `-Djava.net.preferIPv4Stack=true` flag causes the JVM networking stack to violently reject the operation, as the JVM was instructed to only use the OS's IPv4 stack.
4. The connection attempt immediately collapses with an exception:
   `io.grpc.netty.shaded.io.netty.channel.AbstractChannel$AnnotatedConnectException: connect(..) failed: Address family not supported by protocol: /[2001:4860:8040:147:0:56a:af15:ef5f]:25441`
5. gRPC's internal load balancer attempts to fall back to the next address in the xDS endpoint list. However, because *all* DirectPath backend endpoints are IPv6, every single subsequent connection attempt also blows up with the exact same error.
6. **The Silent Fallback**: Once the entire xDS endpoint list is exhausted and all connections fail, the `xds` resolver mechanism assumes the internal DirectPath cluster is completely inaccessible.
7. To prevent complete application failure, gRPC aborts the `xds` schema entirely and transparently falls back to standard `dns:///bigtable.googleapis.com` resolution.
8. Standard DNS resolves to the public, external IPv4 VIPs for Google APIs (the Cloud Front End).
9. The client successfully connects to these IPv4 external VIPs, routing all traffic through the CFE. This creates the illusion that the client is functioning correctly (because requests succeed), while entirely missing the DirectPath routing.

Removing both `preferIPv4` flags allows the JVM to create standard dual-stack sockets, smoothly connecting to the internal IPv6 DirectPath backend endpoints provided by xDS.
