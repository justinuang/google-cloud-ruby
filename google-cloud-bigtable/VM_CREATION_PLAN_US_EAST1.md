# VM Creation Plan for `us-east1-b`

The objective is to create a new testing VM in `us-east1-b` to closely match the Bigtable cluster location (`ju-ruby-sidecar`) for optimal latency. To ensure a clean and isolated environment, we will create a dedicated Virtual Private Cloud (VPC) network and Subnet for this new VM.

## Understanding GCP Networking Concepts

Before diving into the plan, here's a brief breakdown of how these networking components interact in Google Cloud:

*   **VPC (Virtual Private Cloud) / Network:** Think of a VPC as a global, virtual version of a physical network router and switches in a traditional data center. It provides global connectivity for your GCP resources. It spans all regions, but by itself, it doesn't give IP addresses to your VMs.
*   **Subnet (Subnetwork):** A Subnet is a regional slice of a VPC with a specific IP address range (CIDR block). When you create a VM, you must attach it to a specific Subnet in the zone where you are deploying the VM. The VM gets its internal IP from this Subnet's range.
*   **Private Google Access (PGA):** This is a setting at the **Subnet** level. By default, VMs only having internal (private) IP addresses cannot reach public Google APIs (like Bigtable, Cloud Storage, etc.). Enabling PGA allows VMs in that Subnet to securely access Google APIs and services using Google's internal network backbone without needing an external (public) IP address. This is critical for secure, high-performance CloudPath/DirectPath routing.

**How they interact:** You create a global **VPC Network**. Within that network, you define a regional **Subnet** (e.g., in `us-east1`) and assign it an IP range. You enable **Private Google Access** on that Subnet. Finally, you launch your **VM** in a zone within that region (e.g., `us-east1-b`) and attach it to that Subnet, granting it private internal access to Google Services.

**What happens if you don't create a VPC?**
When you create a brand new Google Cloud Project, GCP automatically provisions a single, global VPC network named `default`. This special network operates in **"auto mode"**, meaning Google automatically creates one Subnet inside every single GCP region across the globe for you (e.g., a subnet natively exists in `us-east1`, another in `us-central1`, etc.) with pre-defined IP ranges. Private Google Access is typically disabled by default on these subnets.

If you know nothing about networking and just click "Create VM" in `us-east1-b`, GCP automatically attaches your VM to that pre-built `default` network's `us-east1` Subnet!

**Why can't we just use the `default` network here?**
Earlier, I investigated the `default` network within this specific project (`autonomous-mote-782`). It was set to `LEGACY` mode and completely lacked a subnet in `us-east1`. It appears someone previously modified or deleted the auto-generated networking infrastructure in this project! Therefore, if you try to randomly spin up a VM in `us-east1-b` right now without specifying a network, it will actually crash because the `default` subnet simply doesn't exist anymore to give it an IP address.

That's why our only options were to either use the existing `debug-network` (which was set up similarly to how a default auto-network normally acts) or cleanly mint a brand new custom network from scratch.

## Proposed Changes

### 1. Create an Auto-Mode VPC Network
We will create a new VPC network. As requested, we will use **auto mode**. This is a great shortcut because instead of us manually defining IP ranges and creating a subnet for `us-east1`, Google will automatically generate a subnet in every single region (including `us-east1`) for us with predefined IP ranges!
All resources will be prefixed with `ju-ruby-sidecar`.

```bash
gcloud compute networks create ju-ruby-sidecar-vpc \
  --subnet-mode=auto
```

### 2. Enable Private Google Access on the Auto-Created Subnet
Even though the subnet in `us-east1` is created automatically, Private Google Access (PGA) is **disabled by default**. We must explicitly run an update on that specific auto-created subnet to enable it.

**What does `--enable-private-ip-google-access` do?**
This is strictly a **subnet-level** setting (you cannot configure this directly on the VM). To understand it, you need to understand the two types of IP addresses a VM can have:

*   **Internal (Private) IP:** Every VM gets an internal IP from its subnet's range (e.g., `10.0.0.5`). This IP is only routable *within* your VPC. Without an External IP (or a Cloud NAT), the VM cannot initiate outbound connections to the public internet (egress), meaning it cannot browse the web or hit public APIs.
*   **External (Public) IP:** This is an optional, globally routable IP address (e.g., `34.120.x.x`). Having an external IP means the VM can initiate outbound connections to the public internet. It *also* means the VM is publicly visible—the public internet can potentially initiate inbound connections (ingress) to reach the VM, assuming your VPC firewall rules allow it!

Normally, if a VM *only* has an Internal IP, it is completely cut off from the outside world (both inbound and outbound), which includes public Google Services like Bigtable, Cloud Storage, etc.

**Enabling Private Google Access (PGA)** on the subnet changes this. It creates a special internal route so that VMs with *only* internal IPs can securely reach Google Services by sending traffic over Google's internal network backbone, rather than traversing the public internet.

*   **For CloudPath:** If your VM lacks an External IP, PGA is **mandatory** to reach Bigtable via CloudPath. (If your VM *does* have an External IP, it can reach CloudPath via the public internet gateway anyway).
*   **For DirectPath:** DirectPath is specifically designed to bypass Cloud Load Balancers and establish direct internal connections to Bigtable servers. Therefore, avoiding External IPs and utilizing internal routing (by ensuring PGA is enabled) is considered a best practice and often a strict requirement for DirectPath networking to engage successfully without public egress routing issues.

```bash
gcloud compute networks subnets update ju-ruby-sidecar-vpc \
  --region=us-east1 \
  --enable-private-ip-google-access
```

### 3. Create the `ju-ruby-sidecar-vm` VM
We will create the new 16-core VM attached to the auto-created subnet in the `us-east1-b` zone. Note that we just specify the network name, and GCP knows to use the subnet in that region.

```bash
gcloud compute instances create ju-ruby-sidecar-vm \
  --zone=us-east1-b \
  --machine-type=e2-standard-16 \
  --network=ju-ruby-sidecar-vpc \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --image-family=debian-12 \
  --image-project=debian-cloud
```

### 4. Environment Setup (Future Execution Phase)

*Note: No mutations happen during this planning phase.*
Once the infrastructure is provisioned, the plan is to SSH into `ju-ruby-sidecar-vm` and install the identical Ruby (`rvm`, `ruby 3.3.0`, `bundler`) and Java (`openjdk-17-jdk`, `maven`) toolchains.

## User Review Required

Please review the explanations and the updated commands for creating the custom VPC and Subnet. Once approved, I am ready to jump into EXECUTION and run these commands to spin up the new environment.
