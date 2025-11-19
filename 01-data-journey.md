# The Journey of Data: From Application to the Wire

## Overview

When an application calls `write()` to send data over a socket, that data travels through multiple layers of the Linux networking stack before becoming electrical signals on the wire. Understanding this journey is essential for optimizing latency and throughput because each layer introduces potential delays through copying, queuing, and processing.

This document traces the complete path from application memory to physical transmission, identifying where latency accumulates and what can be controlled.

## Layer 1: Application User Space

### The Starting Point: Application Memory

An application has data in its own memory space that needs to be sent over the network. This might be a message, request, or file data formatted as JSON, XML, binary protocol, or raw bytes.

**Key Concept**: This data is in *user space* memory, which the kernel cannot directly access. It must be copied into *kernel space*.

### The write() or send() System Call

`write()` is a generic file-descriptor call that simply sends bytes into a socket, while `send()` is the socket-specific version that supports networking flags and advanced control. In practice, both deliver data to the kernel, but `send()` gives proper network semantics.

When an application calls `write()` or `send()` on a socket:

```
1. CPU switches from user mode to kernel mode (privilege escalation)
2. Kernel validates parameters (valid file descriptor, readable buffer, etc.)
3. Kernel locates the socket structure in kernel memory
4. Kernel copies data from user space buffer to socket send buffer
5. Kernel updates socket buffer pointers and counters
6. CPU switches back to user mode
7. `write()` returns to the application
```
**Critical Point**: `write()` or `send()` does NOT wait for data to be transmitted on the wire. It only waits for data to be copied into the kernel's socket send buffer. If that buffer is full, `write()` will either block (for blocking sockets) or return `EAGAIN` (for non-blocking sockets).

### The System Call Boundary

At the CPU level, the system call transition involves:

```
User Mode:
  Arguments pushed to registers/stack
  syscall instruction executed
    ↓
Kernel Mode:
  Save user context (registers, instruction pointer)
  Execute kernel function
  Restore user context
  Return to user mode
```

**Latency Impact**: This context switch costs 50-200 nanoseconds on modern CPUs. Not huge individually, but it accumulates when making many small writes. Buffering writes in user space before calling `write()` reduces this overhead.

## Layer 2: Socket Send Buffer (Kernel Space)

### What Is the Socket Send Buffer?

The socket send buffer (`SO_SNDBUF`) is a kernel memory region associated with each socket. It acts as a staging area between an application and the TCP stack, implemented as a linked list of `sk_buff` structures (socket buffers) - the fundamental unit of packet storage in the Linux kernel.

### Buffer Architecture in Memory

```
User Space:
  [Application Memory]
           |
           | write() system call - DATA COPY
           v
Kernel Space:
  [Socket Send Buffer - Ring Buffer]
    - Size: controlled by SO_SNDBUF
    - Type: Kernel memory (sk_buff structures)
    - Management: TCP stack owns this
           |
           | TCP segments and sends
           v
  [TCP Output Queue]
```

### Configuring Socket Buffers

Socket buffer sizes are controlled using `setsockopt()` with `SO_SNDBUF` and `SO_RCVBUF` options. Key points:

**Buffer Size Behavior**:
- Request a size (e.g., 128KB)
- Kernel may double it for internal bookkeeping overhead
- Actual allocated size may differ from requested size

**Typical Settings for Low-Latency Systems**:
- Small buffers (64-128KB): Lower latency, less queuing delay
- Large buffers (256KB+): Higher throughput, more buffering capacity
- The choice depends on RTT and bandwidth requirements

**Related Options**:
- `TCP_NODELAY`: Disables Nagle's algorithm for immediate sending (critical for low latency)
- `SO_RCVBUF`: Receive buffer size (affects TCP window size)
- Kernel limits: `/proc/sys/net/core/rmem_max` and `wmem_max`

### The Meaning of a Successful write() Call

**Critical Understanding**: A successful return from a `write()` call *only indicates that the data has been copied into the kernel's socket send buffer*. 
This allows the application to immediately reuse its own buffer. 
```
Application Buffer → memcpy() → Socket Send Buffer (sk_buff)
    ↓
write() returns successfully
```

It **does not** mean:
- The data has reached the peer
- The data has even left the local machine
- The data has been acknowledged

The application can continue executing while the kernel handles the actual transmission asynchronously.

### What Happens When the Socket Buffer Fills Up?

This is critical for understanding latency behavior:

**Blocking Socket (default)**:

By default, sockets operate in blocking mode. If the socket send buffer has insufficient free space to accept **all** the data from the application's `write()` call, the kernel will put the application process to sleep. The process will not be scheduled to run again until the kernel has managed to copy the *entire* application buffer into the socket send buffer.

```
Kernel checks SO_SNDBUF size
    ↓
Is there enough space in socket send buffer?
    ├─ YES → Copy all data immediately
    └─ NO  → Copy as much data as fits → Block process (sleep) until space available
```

**Buffer State Check**:
```
Available space = SO_SNDBUF - current_data_in_buffer

If (data_to_write > available_space):
    - Process sleeps (blocking socket)
    - Waits for ACKs to free buffer space
    - Eventually woken up when space available
```

The application waits, adding latency to the operation. This is predictable behavior but can cause head-of-line blocking.

**Non-blocking Socket**:

With non-blocking sockets, `write()` returns immediately with `EAGAIN` error if buffer is full. The application must handle this (typically using `select()`, `poll()`, or `epoll()`). More complex but allows concurrent operations.

**For low-latency systems**: Blocking sockets are usually acceptable if buffers are correctly sized. A full socket buffer indicates the network can't keep up with the sending rate, a configuration problem that needs addressing at the system level, not the application level.

## Layer 3: TCP Segmentation Engine

### From Application Data to TCP Segments

The kernel's TCP stack takes over. It pulls data from the socket send buffer and breaks it into segments. The size of these segments is typically governed by the **Maximum Segment Size (MSS)**, which is advertised by the peer during the TCP handshake. TCP prepends its own header to each segment.

### TCP Segmentation Process

```
Socket Send Buffer (may contain multiple application writes)
    ↓
TCP examines:
    - Peer's MSS (Maximum Segment Size)
    - Congestion window (cwnd)
    - Available data
    ↓
Segment data into chunks ≤ MSS
```

**MSS Determination**:
- If peer sent MSS option: Use announced value (e.g., 1460 bytes for Ethernet)
- If no MSS option: Default to 536 bytes
- With Path MTU Discovery: Adjust to avoid fragmentation

**Congestion Window (cwnd)**: TCP won't send more unacknowledged data than the congestion window allows, even if the socket buffer has more data ready. This is TCP's congestion control mechanism.

### TCP Segment Structure

For each segment (≤ MSS):
```
┌─────────────────────────────────────┐
│ TCP Header (20-60 bytes)            │
│  - Source port, Dest port           │
│  - Sequence number                  │
│  - ACK number                       │
│  - Flags (PSH, ACK, etc.)           │
│  - Window size                      │
│  - Checksum                         │
│  - Options (timestamps, SACK, etc.) │
├─────────────────────────────────────┤
│ Data Payload (≤ MSS)                │
└─────────────────────────────────────┘
```

### TCP Retransmission Queue

**Critical for reliability**: TCP maintains a copy of every sent segment until it's acknowledged.

```
TCP segment → Copied to retransmission queue
                    ↓
            Segment sent to IP layer
                    ↓
    Original copy RETAINED until ACK received
```

**Key mechanism**:
- TCP maintains copy in retransmission queue
- Timer started for each segment (RTO - Retransmission TimeOut)
- Only when ACK arrives:

```
ACK received for sequence numbers X to Y
    ↓
Remove acknowledged data from:
    - Retransmission queue
    - Socket send buffer
    ↓
Wake up blocked write() calls (if any)
```

**Latency Impact**: The retransmission queue is what allows TCP to be reliable, but it also means data stays in kernel memory (consuming socket buffer space) until acknowledged. This is why ACKs directly affect how quickly `write()` calls can proceed when buffers are nearly full.

### Serialization Time on the Wire

The time to physically transmit a segment depends on link speed:

**At 1 Gbps**:
- 1460 bytes = 11.68 microseconds
- 4000 bytes total ≈ 32 microseconds

**At 10 Gbps**:
- 1460 bytes = 1.168 microseconds
- 4000 bytes total ≈ 3.2 microseconds

This is pure serialization time - actual transmission includes all the other layers' processing overhead.

## Layer 4: IP Layer - Routing and Fragmentation

### The IP Layer's Job

TCP passes the segment to the IP layer, which prepends the IP header. The IP layer performs a route lookup to determine the correct outgoing network interface (e.g., `eth0`) and the next-hop MAC address.

### IP Header Structure

```
TCP segment received
    ↓
IP prepends header (20-60 bytes)
    ↓
┌─────────────────────────────────────┐
│ IP Header (20 bytes minimum)        │
│  - Version (IPv4/IPv6)              │
│  - Header length                    │
│  - Total length                     │
│  - Identification, Flags, Fragment  │
│  - TTL, Protocol (6 for TCP)        │
│  - Source IP, Destination IP        │
│  - Checksum                         │
├─────────────────────────────────────┤
│ TCP Header + Data                   │
└─────────────────────────────────────┘
    ↓
Routing table lookup: ip_route_output()
```

### Routing Decision

```
Destination IP lookup in routing table
    ↓
Matches route entry (longest prefix match)
    ↓
Route entry specifies:
    - Outgoing interface (eth0, wlan0, etc.)
    - Next hop gateway (if needed)
    - MTU for interface
```

**Latency Impact**: This is a hash table lookup - typically takes nanoseconds on modern systems. Not a significant contributor unless there are thousands of routes.

### IP Fragmentation (Usually Avoided)

If a TCP segment + IP header exceeds the link MTU, IP would need to fragment the packet. However:

**Modern TCP avoids this** using **Path MTU Discovery (PMTUD)**:
- TCP sends packets with the "Don't Fragment" (DF) bit set
- If a router can't forward the packet due to MTU, it sends back an ICMP "Fragmentation Needed" message
- TCP adjusts its MSS accordingly

**Fragmentation Check**:
```
Datagram size > interface MTU?
    ├─ NO  → Send as-is
    └─ YES → Fragment into smaller packets
            (unless DF flag set, then ICMP error)
```

**Why Fragmentation Is Bad for Latency**:
1. Reassembly at destination adds delay
2. If any fragment is lost, the entire packet must be retransmitted
3. Many firewalls drop fragments for security reasons

## Layer 5: Queueing Discipline (qdisc)

### The Network Traffic Manager

Before packets reach the network interface card (NIC), they pass through the **queueing discipline** (qdisc) layer. This implements traffic shaping, prioritization, and rate limiting.

**Default qdisc on RHEL 8**: `fq_codel` (Fair Queue Controlled Delay)

### Queue Structure and States

```
IP Layer Output
    ↓
[Qdisc - fq_codel by default]
  - Multiple queues (one per flow)
  - CoDel active queue management
  - Configurable queue depth
    ↓
NIC Driver
```

The IP packet is handed to the datalink driver (e.g., the NIC driver). This driver places the packet onto its **output queue (txqueue)**, waiting for the hardware to transmit it onto the wire.

**Interface Output Queue Details**:
```
IP datagram ready
    ↓
Passed to network device driver
    ↓
Check interface output queue (qdisc - queuing discipline)
```

**Queue States**:
```
┌──────────────────────────────────┐
│  Interface Output Queue (qdisc)  │
│  - Default: pfifo_fast           │
│  - Size: txqueuelen (typically   │
│    1000 packets)                 │
└──────────────────────────────────┘
        ↓
Is queue full?
    ├─ NO  → Enqueue packet
    └─ YES → Drop packet → Return error
```

### Why Qdisc Matters for Latency

**This is where packets wait**. If the qdisc queue is deep and packets are accumulating, each packet adds measurable latency.

Example with 1000-packet queue at 1 Gbps with 1500-byte packets:
- Time to drain one packet: ~12 microseconds
- Time to drain 1000 packets: ~12 milliseconds

**For latency-sensitive applications**, 12ms is significant, especially when accumulated across multiple network hops.

### Error Handling When Queue is Full

If the output queue is full (a sign of congestion or a slow link), the packet is typically discarded. **TCP will not receive an immediate error**, but it will eventually detect the data loss (e.g., via a timeout) and retransmit the segment later, introducing significant latency.

**Error Propagation**:
```
Packet dropped at datalink layer
    ↓
Error propagated UP the stack:
    Datalink → IP → TCP
    ↓
TCP notes the error
    ↓
TCP will retry transmission later (based on RTO)
    ↓
Application is NOT notified (transient condition)
```

This is a **critical point**: Queue drops don't immediately fail the application's `write()` call. The application thinks data was sent successfully, but TCP will handle retransmission transparently in the background. However, this adds latency to the overall operation.

### Checking Qdisc Configuration

```bash
# View current qdisc on interface eth0
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tc qdisc show dev $DEFAULT_IF

# Output example:
# qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514
#   target 5.0ms interval 100.0ms memory_limit 32Mb ecn
```

We'll cover qdisc tuning in detail in [05-queueing-congestion.md](05-queueing-congestion.md).

## Layer 6: NIC Driver and Ring Buffers

### Ring Buffers: Hardware-Software Interface

The NIC (Network Interface Card) driver manages **ring buffers** - circular queues in RAM that the NIC hardware can directly access via DMA (Direct Memory Access).

### TX Ring Buffer (Transmit)

```
Kernel Driver:
  [Packet 1] -> [Packet 2] -> [Packet 3] -> ... [Packet N]
      ^                                          |
      |                                          |
      +--- head pointer                tail pointer ---+
                                                       |
                                                       v
                                              NIC Hardware reads
                                              and transmits
```

**Size Considerations**:
- Too small: CPU may stall waiting for NIC to process packets
- Too large: More packets queued = more latency under load

### Checking Ring Buffer Size

```bash
# View current ring buffer settings for eth0
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ethtool -g $DEFAULT_IF

# Output example:
# Ring parameters for eth0:
# Pre-set maximums:
# RX:             4096
# TX:             4096
# Current hardware settings:
# RX:             512
# TX:             512
```

### DMA Operation

When a packet is ready to transmit:

1. **Kernel prepares descriptor** in ring buffer with packet address and length
2. **Kernel updates tail pointer** (writes to NIC register via MMIO)
3. **NIC receives interrupt** or polls ring buffer
4. **NIC performs DMA** to read packet data from RAM
5. **NIC serializes** data onto physical wire
6. **NIC updates head pointer** when complete
7. **NIC generates interrupt** (optional, if not using polling)

**Latency Impact**: DMA transfer time depends on PCIe bus speed. For a 1500-byte packet on PCIe Gen 3 x8: ~150 nanoseconds. Not significant, but it adds up.

## Layer 7: Physical Transmission

### Serialization Onto the Wire

This is the final step: converting bits into electrical signals (for copper) or light pulses (for fiber).

**Serialization Delay Formula**:
```
Serialization_Time = Packet_Size_Bits / Link_Speed_bps

Example for 1500-byte packet at 1 Gbps:
= (1500 bytes × 8 bits/byte) / (1,000,000,000 bits/second)
= 12,000 bits / 1,000,000,000 bps
= 0.000012 seconds = 12 microseconds
```

### The Complete Timeline

Let's trace a 1500-byte packet through the entire stack with realistic timings:

```
Application write():         ~100 ns   (system call overhead)
Copy to socket buffer:       ~200 ns   (memory copy)
TCP processing:              ~500 ns   (segment creation, checksum)
IP routing lookup:           ~100 ns   (route cache hit)
Qdisc enqueue:               ~50 ns    (queue operation)
Driver ring buffer:          ~100 ns   (descriptor setup)
DMA transfer:                ~150 ns   (PCIe)
Serialization (1 Gbps):      ~12 µs    (on the wire)
-----------------------------------------------------------
TOTAL:                       ~13 µs    (best case, no queuing)
```

**Reality Check**: This is the *best case* with no queuing delay. In practice:
- Qdisc queuing: can add milliseconds if buffers are deep
- Socket buffer full: can block indefinitely
- Network congestion: triggers TCP backoff, retransmissions

## The Return Journey: ACKs and Flow Control

### TCP Requires Acknowledgments

TCP is a reliable protocol, so every segment sent must be acknowledged by the receiver. This acknowledgment travels back through the same layers in reverse:

```
Remote Host Wire -> NIC -> Driver -> IP -> TCP -> Socket -> read()
                                     |
                                     +---> ACK generated
                                     |
ACK travels back: Socket -> TCP -> IP -> Driver -> NIC -> Wire
```

### Round Trip Time (RTT) Impact

The `write()` call returns as soon as data is copied to the kernel buffer, but the data isn't truly "sent" until it's acknowledged. For a request-response operation:

```
Time 0:      write() sends request
Time 0:      write() returns (data in kernel buffer)
Time 13µs:   First packet hits wire
Time RTT/2:  Packet arrives at remote server
Time RTT/2:  Server generates response
Time RTT:    Response arrives back
```

**For a typical datacenter RTT of 1-2ms**, the actual round-trip time includes:
- Application processing time
- RTT for request to reach server
- Server processing time
- RTT for response to return

This is why buffer sizing matters - we'll cover this in [07-rtt-buffer-sizing.md](07-rtt-buffer-sizing.md).

## Key Takeaways

1. **Multiple Copies**: Data is copied multiple times (user→kernel, kernel→NIC) before transmission

2. **Every Layer Adds Latency**: 
   - System call overhead: ~100 ns
   - Memory copies: ~200 ns
   - Protocol processing: ~500-1000 ns
   - Serialization: microseconds (depends on link speed)
   - Queuing: can be milliseconds if buffers are full

3. **Buffers Are Queues**: Every buffer in the path is a potential source of queuing delay

4. **write() Returns Early**: Just because `write()` returned doesn't mean data is on the wire or acknowledged

5. **Hardware Limits**: NIC serialization speed and ring buffer sizes impose hard physical limits

## What's Next?

Now that the complete journey is understood, the next documents will dive deeper into:

- **[Hardware and Link Layer](02-hardware-link-layer.md)**: MTU, MSS, and frame sizing
- **[Socket Buffer Architecture](03-socket-buffer-architecture.md)**: Deep dive into SO_SNDBUF/SO_RCVBUF
- **[Queueing and Congestion](05-queueing-congestion.md)**: How to configure qdisc for low latency

---

**Next**: [Hardware and Link-Layer Boundaries](02-hardware-link-layer.md)
