# Socket Buffer Architecture

## Overview

With MTU and MSS understood, the next critical component is the socket buffer system. Socket buffers are kernel memory regions that hold data in transit between applications and the network. Understanding their architecture, sizing requirements, and configuration is essential for optimizing both latency and throughput based on application requirements.

This document explores the internal structure of socket buffers, their relationship to TCP flow control and congestion control, and how to configure them properly for low-latency operations on RHEL/OEL 8 systems.

## Socket Buffer Fundamentals

### The Two Buffers

Every TCP socket has two independent buffers:

**Send Buffer (`SO_SNDBUF`)**:
- Holds outgoing data that has been written by the application but not yet acknowledged by the peer
- Size determines how much data can be "in flight" on the network
- When full, subsequent `write()` calls block (or return `EAGAIN` for non-blocking sockets)

**Receive Buffer (`SO_RCVBUF`)**:
- Holds incoming data that has been received from the network but not yet read by the application
- Size directly determines the TCP receive window advertised to the peer
- Cannot overflow because TCP flow control prevents peer from sending beyond the advertised window

### Socket Buffer Structure in Kernel Memory

```
┌────────────────────────────────────────────────────────────────┐
│ SOCKET BUFFER ARCHITECTURE                                     │
│                                                                │
│ User Space                                                     │
│ ┌─────────────────────────────────────────┐                    │
│ │ Application                             │                    │
│ │                                         │                    │
│ │  write(sockfd, buf, len) ──┐            │                    │
│ │                            │            │                    │
│ │  read(sockfd, buf, len) ◄──┼────────────┤                    │
│ │                            │            │                    │
│ └────────────────────────────┼────────────┘                    │
│                              │                                 │
│ ════════════════════════════ KERNEL BOUNDARY ══════════════════│
│                              │                                 │
│ Kernel Space                 │                                 │
│                              ▼                                 │
│ ┌─────────────────────────────────────────────────────────┐    │
│ │ Socket Structure (struct sock)                          │    │
│ │                                                         │    │
│ │  Send Buffer (sk_write_queue)      Receive Buffer       │    │
│ │  ┌────────────────────┐             ┌────────────────┐  │    │
│ │  │ sk_buff list       │             │ sk_buff list   │  │    │
│ │  │ ┌──────┐           │             │ ┌──────┐       │  │    │
│ │  │ │ skb1 │───┐       │             │ │ skb1 │───┐   │  │    │
│ │  │ └──────┘   │       │             │ └──────┘   │   │  │    │
│ │  │ ┌──────┐◄──┘       │             │ ┌──────┐◄──┘   │  │    │
│ │  │ │ skb2 │───┐       │             │ │ skb2 │───┐   │  │    │
│ │  │ └──────┘   │       │             │ └──────┘   │   │  │    │
│ │  │ ┌──────┐◄──┘       │             │ ┌──────┐◄──┘   │  │    │
│ │  │ │ skb3 │           │             │ │ skb3 │       │  │    │
│ │  │ └──────┘           │             │ └──────┘       │  │    │
│ │  │                    │             │                │  │    │
│ │  │ Size: SO_SNDBUF    │             │ Size: SO_RCVBUF│  │    │
│ │  │ (e.g., 128KB)      │             │ (e.g., 128KB)  │  │    │
│ │  └────────────────────┘             └────────────────┘  │    │
│ │           │                                   ▲         │    │
│ └───────────┼───────────────────────────────────┼─────────┘    │
│             │                                   │              │
│             ▼                                   │              │
│    ┌─────────────────┐                 ┌─────────────────┐     │
│    │  TCP Output     │                 │  TCP Input      │     │
│    │  Processing     │                 │  Processing     │     │
│    └─────────────────┘                 └─────────────────┘     │
│             │                                   ▲              │
│             ▼                                   │              │
│        To Network                          From Network        │
└────────────────────────────────────────────────────────────────┘
```

### The sk_buff Structure

The Linux kernel uses `sk_buff` (socket buffer) structures as the fundamental unit for packet storage. Each `sk_buff` contains:

```
struct sk_buff {
    // Linked list pointers
    struct sk_buff *next;
    struct sk_buff *prev;
    
    // Socket association
    struct sock *sk;
    
    // Timing information
    ktime_t tstamp;
    
    // Data pointers
    unsigned char *head;    // Start of allocated buffer
    unsigned char *data;    // Start of actual data
    unsigned char *tail;    // End of actual data
    unsigned char *end;     // End of allocated buffer
    
    // Size information
    unsigned int len;       // Length of actual data
    unsigned int data_len;  // Length of paged data
    
    // Protocol headers
    // ... (many more fields)
};
```

**Key Points**:
- Each packet or segment is stored as an `sk_buff`
- Multiple `sk_buff` structures are linked in a queue (doubly-linked list)
- The send buffer holds `sk_buff` structures until they're acknowledged
- The receive buffer holds `sk_buff` structures until the application reads them

## SO_RCVBUF and SO_SNDBUF Socket Options

### Receive Buffer (SO_RCVBUF)

The receive buffer is used by TCP to hold received data **until it is read by the application**. 

**Critical Behavior**:
- **The available room in the socket receive buffer limits the window** that TCP can advertise to the other end
- The TCP socket receive buffer **cannot overflow** because the peer is not allowed to send data beyond the advertised window
- This is TCP's flow control mechanism
- If the peer ignores the advertised window and sends data beyond it, the receiving TCP discards the data

**TCP Window and Flow Control**:

```
┌────────────────────────────────────────────────────────────────┐
│ TCP FLOW CONTROL WITH RECEIVE BUFFER                           │
│                                                                │
│ Receiver                                                       │
│ ┌──────────────────────────────────────────────────┐           │
│ │ SO_RCVBUF = 64KB                                 │           │
│ │                                                  │           │
│ │ ┌──────────────┐  ┌─────────────────────────┐    │           │
│ │ │ Data (40KB)  │  │ Free Space (24KB)       │    │           │
│ │ │ Not yet read │  │                         │    │           │
│ │ │ by app       │  │ ◄─ Advertised Window    │    │           │
│ │ └──────────────┘  └─────────────────────────┘    │           │
│ └──────────────────────────────────────────────────┘           │
│                                                                │
│ TCP advertises window = 24KB to sender                         │
│                                                                │
│ Sender                                                         │
│ ┌──────────────────────────────────────────────────┐           │
│ │ Can send UP TO 24KB without waiting for ACK      │           │
│ │                                                  │           │
│ │ If sender tries to send more:                    │           │
│ │  - TCP will not send (respects receiver window)  │           │
│ │  - Data queues in sender's SO_SNDBUF             │           │
│ │  - Eventually blocks application write()         │           │
│ └──────────────────────────────────────────────────┘           │
└────────────────────────────────────────────────────────────────┘
```

### Send Buffer (SO_SNDBUF)

The send buffer holds data that has been written by the application but:
- Has not yet been transmitted by TCP, OR
- Has been transmitted but not yet acknowledged by the peer

**Critical Behavior**:
- Data remains in send buffer until acknowledged (for potential retransmission)
- When buffer is full, `write()` blocks (blocking socket) or returns `EAGAIN` (non-blocking)
- Buffer size limits how much unacknowledged data can be "in flight"
- Acknowledgments free space in the send buffer, potentially unblocking writes

**Send Buffer States**:

```
┌────────────────────────────────────────────────────────────────┐
│ SEND BUFFER STATES                                             │
│                                                                │
│ SO_SNDBUF = 64KB                                               │
│ ┌────────────────────────────────────────────────────────┐     │
│ │ ┌──────────────┐ ┌────────────┐ ┌──────────────────┐   │     │
│ │ │ Segment 1    │ │ Segment 2  │ │ Free Space       │   │     │
│ │ │ Sent,        │ │ Sent,      │ │                  │   │     │
│ │ │ Not ACK'd    │ │ Not ACK'd  │ │ Available for    │   │     │
│ │ │ (In flight)  │ │ (In flight)│ │ new writes       │   │     │
│ │ └──────────────┘ └────────────┘ └──────────────────┘   │     │
│ └────────────────────────────────────────────────────────┘     │
│                                                                │
│ When ACK arrives for Segment 1:                                │
│ ┌────────────────────────────────────────────────────────┐     │
│ │ ┌────────────┐ ┌─────────────────────────────────────┐ │     │
│ │ │ Segment 2  │ │ Free Space (larger now)             │ │     │
│ │ │ Sent,      │ │                                     │ │     │
│ │ │ Not ACK'd  │ │ Segment 1 removed from buffer       │ │     │
│ │ └────────────┘ └─────────────────────────────────────┘ │     │
│ └────────────────────────────────────────────────────────┘     │
│                                                                │
│ Blocked write() calls can now proceed                          │
└────────────────────────────────────────────────────────────────┘
```

### Buffer Size and Window Scaling

**Critical Timing**: When setting the size of the TCP socket receive buffer, the ordering of function calls is important. This is because of TCP's window `scale` option, which is exchanged with the peer on the `SYN` segments **when the connection is established**.

**For a client**:
```c
// CORRECT order
int sockfd = socket(AF_INET, SOCK_STREAM, 0);

int rcvbuf = 262144;  // 256KB
setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
// ↑ MUST be set BEFORE connect()

connect(sockfd, ...);  // SYN sent with window scale calculated from SO_RCVBUF
```

**For a server**:
```c
// CORRECT order
int listenfd = socket(AF_INET, SOCK_STREAM, 0);

int rcvbuf = 262144;  // 256KB
setsockopt(listenfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
// ↑ MUST be set on listening socket BEFORE listen()

bind(listenfd, ...);
listen(listenfd, ...);  // Window scale now applies to all accepted connections

int connfd = accept(listenfd, ...);  // Inherits window scale from listening socket
```

**Why This Matters**:

TCP's window field in the header is only 16 bits (max value 65,535). To support larger buffers, TCP uses a window scale factor negotiated during the handshake. The kernel calculates this scale based on `SO_RCVBUF` at handshake time.

```
Without Window Scaling:
  Maximum window = 65,535 bytes
  Maximum throughput = 65,535 bytes / RTT

With Window Scaling (factor = 7):
  Maximum window = 65,535 × 2^7 = 8,388,480 bytes
  Can support much larger buffers and higher throughput
```

Setting `SO_RCVBUF` after the connection is established has **no effect** on window scaling because the scale factor was already negotiated during the handshake.

## MSS and Buffer Size Relationship

### The 4× MSS Rule

TCP socket buffer sizes should be **at least four times the MSS** for the connection. This applies to:
- Both socket buffer sizes (send and receive) on the sender
- Both socket buffer sizes (send and receive) on the receiver
- For bidirectional data transfer

**Why 4× MSS?**

The minimum MSS multiple of four is a result of the way that TCP's fast recovery algorithm works. The TCP sender uses **three duplicate acknowledgments** to detect that a packet was lost (RFC 2581). The receiver sends a duplicate acknowledgment for each segment it receives after a lost segment. 

If the window size is smaller than four segments, there cannot be three duplicate acknowledgments, so the fast recovery algorithm cannot be invoked.

```
┌────────────────────────────────────────────────────────────────┐
│ TCP FAST RECOVERY REQUIRES 4 SEGMENTS                          │
│                                                                │
│ Sender sends 4 segments:                                       │
│ ┌────┐ ┌────┐ ┌────┐ ┌────┐                                    │
│ │ S1 │ │ S2 │ │ S3 │ │ S4 │                                    │
│ └────┘ └────┘ └────┘ └────┘                                    │
│   │      │      │      │                                       │
│   ▼      ▼      ▼      ▼                                       │
│                                                                │
│ Segment 2 is LOST                                              │
│ ┌────┐  LOST  ┌────┐ ┌────┐                                    │
│ │ S1 │   ✗    │ S3 │ │ S4 │                                    │
│ └────┘        └────┘ └────┘                                    │
│   │             │      │                                       │
│   ▼             ▼      ▼                                       │
│                                                                │
│ Receiver:                                                      │
│  - Receives S1: Sends ACK 1                                    │
│  - S2 missing: Expecting S2                                    │
│  - Receives S3: Still expecting S2, sends DUP ACK 1            │
│  - Receives S4: Still expecting S2, sends DUP ACK 1            │
│                                                                │
│ Sender receives:                                               │
│  ACK 1, DUP ACK 1, DUP ACK 1, DUP ACK 1                        │
│          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^                        │
│          3 duplicate ACKs = Fast Recovery                      │
│                                                                │
│ Fast Recovery: Retransmit S2 immediately (~1 RTT)              │
│                                                                │
│ If window < 4 segments:                                        │
│  - Cannot generate 3 dup ACKs                                  │
│  - Must wait for RTO timeout (200ms - 1s+)                     │
│  - Much higher latency!                                        │
└────────────────────────────────────────────────────────────────┘
```

**Calculation**:

```
MSS = 1460 bytes (typical for standard Ethernet)

Minimum buffer = 4 × MSS
               = 4 × 1460
               = 5,840 bytes

Recommended (round up to power of 2):
               = 8,192 bytes (8KB)

For low-latency systems:
  Typical range: 64KB - 256KB
  
  Example: 128KB buffer
  = 131,072 bytes
  = 131,072 / 1460 segments
  = ~89 segments can be buffered
```

### Buffer Size Should Be Multiple of MSS

To avoid wasting buffer space, the TCP socket buffer sizes should be an even multiple of the MSS for the connection.

**Why?**

```
Example with non-aligned buffer:

MSS = 1460 bytes
Buffer = 10,000 bytes

10,000 / 1460 = 6.849... segments

Can fit: 6 complete segments = 8,760 bytes
Wasted:  10,000 - 8,760 = 1,240 bytes (12.4% waste)

Better choice: 8,760 bytes (6 × MSS) or 11,680 bytes (8 × MSS)
```

In practice, this is less critical than the 4× MSS minimum, but it's still worth considering when tuning for optimal performance.

## Kernel Buffer Limits

Linux imposes system-wide limits on socket buffer sizes to prevent a single application from consuming all kernel memory.

### System-Wide Limits

```bash
# Maximum receive buffer size
cat /proc/sys/net/core/rmem_max
# Typical default: 212992 (208KB)

# Maximum send buffer size  
cat /proc/sys/net/core/wmem_max
# Typical default: 212992 (208KB)

# TCP-specific auto-tuning settings (min, default, max)
cat /proc/sys/net/ipv4/tcp_rmem
# Typical: 4096 131072 6291456
#          min  default max

cat /proc/sys/net/ipv4/tcp_wmem
# Typical: 4096 16384 4194304
#          min  default max
```

**Hierarchy**:
1. Application calls `setsockopt(SO_RCVBUF, value)`
2. Kernel checks against `rmem_max` / `wmem_max`
3. Kernel may double the value for bookkeeping overhead
4. Actual buffer size is capped by system limits

**Important Note**: The kernel typically **doubles** the requested buffer size for internal bookkeeping. This means:
- Request 64KB → Kernel allocates 128KB
- `getsockopt()` returns 131072 (128KB), not 65536
- This is normal behavior

### TCP Auto-Tuning

Modern Linux kernels (including RHEL/OEL 8) have TCP auto-tuning enabled by default:

```bash
# Check if auto-tuning is enabled (should be 1)
cat /proc/sys/net/ipv4/tcp_moderate_rcvbuf
# Output: 1 (enabled)
```

When auto-tuning is enabled:
- Kernel dynamically adjusts socket buffer sizes based on connection characteristics
- Uses the values in `tcp_rmem` and `tcp_wmem` as guidelines
- Can grow buffers up to the max value in `tcp_rmem[2]` and `tcp_wmem[2]`
- Generally works well for bulk transfers
- May not be optimal for low-latency request-response patterns

**For latency-sensitive applications**: Auto-tuning is usually acceptable, but explicit buffer sizing provides more predictable behavior.

## Buffer Configuration on RHEL/OEL 8

### Viewing Current System Limits

```bash
#!/bin/bash
# Show all socket buffer related settings

echo "=== Socket Buffer Limits ==="
echo "rmem_max: $(cat /proc/sys/net/core/rmem_max) bytes"
echo "wmem_max: $(cat /proc/sys/net/core/wmem_max) bytes"
echo ""
echo "=== TCP Memory Settings ==="
echo "tcp_rmem: $(cat /proc/sys/net/ipv4/tcp_rmem)"
echo "tcp_wmem: $(cat /proc/sys/net/ipv4/tcp_wmem)"
echo ""
echo "=== TCP Auto-tuning ==="
echo "tcp_moderate_rcvbuf: $(cat /proc/sys/net/ipv4/tcp_moderate_rcvbuf)"
echo ""
echo "=== TCP Memory Pressure ==="
echo "tcp_mem: $(cat /proc/sys/net/ipv4/tcp_mem)"
```

### Temporarily Increasing Limits

```bash
# Increase maximum socket buffer sizes (active until reboot)

# Allow up to 16MB receive buffers
sudo sysctl -w net.core.rmem_max=16777216

# Allow up to 16MB send buffers
sudo sysctl -w net.core.wmem_max=16777216

# Adjust TCP auto-tuning (min, default, max in bytes)
# Min: 4KB, Default: 128KB, Max: 8MB
sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 8388608"
sudo sysctl -w net.ipv4.tcp_wmem="4096 131072 8388608"

# Verify changes
sysctl net.core.rmem_max net.core.wmem_max
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
```

### Permanently Configuring Limits

```bash
# Edit /etc/sysctl.conf or create /etc/sysctl.d/99-network-buffers.conf
sudo vi /etc/sysctl.d/99-network-buffers.conf

# Add:
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 8388608
net.ipv4.tcp_wmem = 4096 131072 8388608

# Apply settings
sudo sysctl -p /etc/sysctl.d/99-network-buffers.conf
```

### Application-Level Buffer Configuration

Applications set buffer sizes using `setsockopt()`:

```c
#include <sys/socket.h>

int sockfd = socket(AF_INET, SOCK_STREAM, 0);

// Set receive buffer to 256KB
int rcvbuf = 262144;
if (setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0) {
    perror("setsockopt SO_RCVBUF");
}

// Set send buffer to 256KB  
int sndbuf = 262144;
if (setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)) < 0) {
    perror("setsockopt SO_SNDBUF");
}

// Verify actual sizes (kernel may have doubled them)
int actual_rcvbuf, actual_sndbuf;
socklen_t optlen = sizeof(int);

getsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &actual_rcvbuf, &optlen);
getsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, &actual_sndbuf, &optlen);

printf("Requested rcvbuf: %d, Actual: %d\n", rcvbuf, actual_rcvbuf);
printf("Requested sndbuf: %d, Actual: %d\n", sndbuf, actual_sndbuf);
// Typical output:
// Requested rcvbuf: 262144, Actual: 524288 (kernel doubled it)
// Requested sndbuf: 262144, Actual: 524288 (kernel doubled it)
```

## Checking Socket Buffer Usage

### Using ss (Socket Statistics)

```bash
# Show detailed socket information for all TCP connections
ss -tim

# Show for specific destination
ss -tim dst 10.0.0.5

# Output example:
# ESTAB  0  0    192.168.1.10:45678  10.0.0.5:80
#        cubic wscale:7,7 rto:204 rtt:1.5/0.75 
#        rcv_space:14480 rcv_ssthresh:64088
#        skmem:(r0,rb131072,t0,tb87040,f0,w0,o0,bl0,d0)
#               ^^       ^^       ^^
#               |        |        |
#        Read queue  Rcv buf  Snd buf

# Explanation:
# skmem: Socket memory usage
#   r0      = 0 bytes in receive queue (application read everything)
#   rb131072= Receive buffer size = 128KB
#   t0      = 0 bytes in transmit queue (everything sent)
#   tb87040 = Transmit buffer size = 85KB
#   f0      = Forward allocation
#   w0      = Write buffer
#   o0      = Option memory
#   bl0     = Backlog
#   d0      = Dropped
```

### Checking Buffer Fullness

```bash
#!/bin/bash
# Monitor socket buffer utilization

watch -n 1 'ss -tim | grep -A2 "ESTAB"'

# Look for:
# - High values in receive queue (r): Application not reading fast enough
# - High values in transmit queue (t): Network can't send fast enough
# - Frequent changes: Normal traffic flow
# - Static high values: Bottleneck detected
```

## Buffer Sizing Based on Application Profile

### Bandwidth-Delay Product (BDP)

The optimal buffer size is related to the Bandwidth-Delay Product:

```
BDP = Bandwidth × RTT

Example 1: Local datacenter
  Bandwidth = 1 Gbps = 125,000,000 bytes/sec
  RTT = 2 ms = 0.002 sec
  BDP = 125,000,000 × 0.002 = 250,000 bytes = 244 KB

Example 2: Cross-region
  Bandwidth = 1 Gbps = 125,000,000 bytes/sec
  RTT = 50 ms = 0.05 sec
  BDP = 125,000,000 × 0.05 = 6,250,000 bytes = 6.1 MB

For optimal throughput:
  Buffer size ≥ BDP
```

However, for **message delivery systems**, the considerations are different:

### Message Delivery Pattern

Message delivery systems are typically request-response or streaming:
- Send small messages (1-5 KB)
- Receive small responses or acknowledgments
- Care about latency and minimizing data loss, not maximum throughput

**Recommended buffer sizes for message delivery systems**:

```
Small messages (< 10KB), low RTT (< 5ms):
  SO_SNDBUF: 64-128 KB
  SO_RCVBUF: 64-128 KB
  
  Rationale:
  - 4× MSS minimum: 4 × 1460 = 5,840 bytes
  - Round up: 8 KB minimum
  - Add headroom for bursts: 64-128 KB
  - Still small enough to avoid bufferbloat

Medium messages (10-100KB), medium RTT (5-20ms):
  SO_SNDBUF: 128-256 KB
  SO_RCVBUF: 128-256 KB

Large messages (> 100KB), high RTT (> 20ms):
  Consider BDP-based sizing
  May need 512KB - 2MB buffers
```

### Avoiding Bufferbloat

**Bufferbloat**: Excessive buffering causes high latency under load.

For low-latency systems:
- **Smaller buffers** = Less queuing delay
- **Larger buffers** = Higher throughput but more latency under congestion

**Balance**:
```
Buffer too small:
  - Frequent blocking on write()
  - Cannot utilize available bandwidth
  - TCP window too small
  - Fast recovery fails (< 4× MSS)

Buffer too large:
  - Data sits in queue longer
  - Increased latency under load
  - Memory waste
  - More data lost on connection failure

Sweet spot for low-latency systems:
  - Large enough: 4× MSS minimum
  - Small enough: 128-256 KB typical
  - Monitor actual usage with ss -tim
```

## Common Issues and Troubleshooting

### Issue 1: Application Writes Block Frequently

**Symptom**: `write()` calls block or return `EAGAIN` frequently

**Causes**:
1. Send buffer too small
2. Network too slow (bottleneck)
3. Receiver's window too small
4. Congestion on network path

**Diagnosis**:
```bash
# Check if transmit buffer is full
ss -tim dst <remote_ip>

# Look at skmem values:
# skmem:(r0,rb131072,t100000,tb131072,...)
#                    ^^^^^^^  ^^^^^^^
#                    Queue    Buffer
# If t ≈ tb, buffer is full

# Check retransmissions (sign of congestion)
ss -ti dst <remote_ip> | grep -E "retrans|cwnd"
```

**Solutions**:
1. Increase `SO_SNDBUF`
2. Increase system-wide `wmem_max`
3. Check network for packet loss
4. Verify receiver's buffer sizes

### Issue 2: Application Reads Too Slow

**Symptom**: Receive buffer fills up, peer's sending rate drops

**Causes**:
1. Application not calling `read()` frequently enough
2. Application processing too slow
3. Receive buffer too small

**Diagnosis**:
```bash
# Check if receive queue is backed up
ss -tim dst <remote_ip>

# Look at skmem values:
# skmem:(r80000,rb131072,t0,tb131072,...)
#        ^^^^^^  ^^^^^^^
#        Queue   Buffer
# If r is consistently high, application isn't reading

# Check TCP window being advertised
# If window → 0, receiver is flow controlling sender
```

**Solutions**:
1. Increase `SO_RCVBUF`
2. Optimize application read loop
3. Use non-blocking I/O with epoll
4. Consider multiple threads/processes

### Issue 3: Window Scale Not Applied

**Symptom**: Buffer size set to 256KB, but effective window is only 64KB

**Cause**: `SO_RCVBUF` was set after connection established

**Diagnosis**:
```bash
# Capture TCP handshake
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tcpdump -i $DEFAULT_IF -nn 'tcp[tcpflags] & tcp-syn != 0' -v

# Check for window scale option in SYN/SYN-ACK:
# options [mss 1460,nop,wscale 7,...]
#                      ^^^^^^^^^^
# If wscale is missing or too small, window scaling ineffective
```

**Solution**: Ensure `SO_RCVBUF` is set before `connect()` (client) or `listen()` (server)

### Issue 4: Out of Memory for Sockets

**Symptom**: Cannot create new connections, kernel logs "out of socket memory"

**Causes**:
1. Too many connections with large buffers
2. System-wide TCP memory limit reached
3. Memory leak in application

**Diagnosis**:
```bash
# Check current TCP memory usage
cat /proc/net/sockstat
# Output:
# TCP: inuse 150 orphan 0 tw 45 alloc 180 mem 1200

# Check TCP memory limits (in pages)
cat /proc/sys/net/ipv4/tcp_mem
# Output: 188888 251851 377776
#         ^^^^^^ ^^^^^^ ^^^^^^^
#         Low    Pressure High

# mem value from sockstat should be < Pressure value
```

**Solutions**:
1. Increase `tcp_mem` limits
2. Reduce per-socket buffer sizes
3. Close idle connections
4. Fix application memory leaks

## Key Takeaways

1. **Two Independent Buffers**: Every socket has separate send and receive buffers
   - Send buffer: Holds unacknowledged data
   - Receive buffer: Holds data until application reads it

2. **Receive Buffer Controls TCP Window**: Available receive buffer space determines the window advertised to the peer
   - This is TCP's flow control mechanism
   - Peer cannot send beyond advertised window

3. **Set Buffers Before Connection**: For `SO_RCVBUF`, timing matters
   - Client: Set before `connect()`
   - Server: Set on listening socket before `listen()`
   - Window scale option is negotiated during handshake

4. **4× MSS Minimum**: Buffers should be at least 4× MSS
   - Required for TCP fast recovery (3 duplicate ACKs)
   - Smaller buffers force slow RTO-based recovery
   - Typical minimum: 4 × 1460 = 5,840 bytes → round to 8 KB

5. **System-Wide Limits**: Kernel imposes maximum buffer sizes
   - Check `rmem_max` and `wmem_max`
   - Kernel may double requested sizes for bookkeeping
   - TCP auto-tuning adjusts buffers dynamically

6. **Low-Latency System Sizing**: For request-response patterns
   - 64-128 KB typical range
   - Smaller than BDP-based sizing (lower latency)
   - Monitor actual usage with `ss -tim`
   - Adjust based on message sizes and RTT

7. **Trade-offs**: Buffer sizing involves balancing
   - Too small: Blocking, poor throughput, fast recovery disabled
   - Too large: Bufferbloat, high latency under load, memory waste
   - Monitor and tune based on actual traffic patterns

## Applied Buffer Sizing Decision Tree

*All values are examples*
```
net.core.wmem_max=16777216
# 16 MiB max send buffer; high enough for 10G links but not excessively large.
# Must be ≥ net.ipv4.tcp_wmem[2] (the max TCP send buffer).

net.core.rmem_max=16777216
# 16 MiB max receive buffer; must be ≥ net.ipv4.tcp_rmem[2].

net.core.wmem_default=1048576
# 1 MiB default send buffer; matches net.ipv4.tcp_wmem[1]

net.core.rmem_default=1048576
# 1 MiB default receive buffer; matches net.ipv4.tcp_rmem[1].

                       tcp_wmem[0] tcp_wmem[1] tcp_wmem[2]
# net.ipv4.tcp_wmem = "65536       1048576     16777216"
net.ipv4.tcp_wmem="65536 1048576 16777216"
# min:     64 KiB
# default: 1 MiB
# max:     16 MiB
                       tcp_rmem[0] tcp_rmem[1] tcp_rmem[2]
# net.ipv4.tcp_rmem = "65536       1048576     16777216"
net.ipv4.tcp_rmem="65536 1048576 16777216"
# Symmetric with tcp_wmem: easier to reason about flow control in both directions.

┌─────────────────────────────────────────────────────────────────┐
│                    APPLICATION LAYER                            │
└────────────────┬────────────────────────────────────────────────┘
                 │
        ┌────────▼─────────┐
        │ socket() called  │
        └────────┬─────────┘
                 │
        ┌────────▼─────────────────────────────────┐
        │ Is it a TCP socket?                      │
        └────┬─────────────────────────┬───────────┘
             │ YES (SOCK_STREAM)       │ NO (SOCK_DGRAM, etc.)
             │                         │
    ┌────────▼─────────┐      ┌────────▼──────────┐
    │   TCP PATH       │      │   NON-TCP PATH    │
    └────────┬─────────┘      └────────┬──────────┘
             │                         │
    ┌────────▼──────────────┐ ┌────────▼──────────────────┐
    │ Initial buffer size:  │ │ Initial buffer size:      │
    │ tcp_rmem[1]           │ │ net.core.rmem_default     │
    │ (e.g., 1 MiB)         │ │ (e.g., 1 MiB)             │
    └────────┬──────────────┘ └────────┬──────────────────┘
             │                         │
    ┌────────▼──────────────┐          │
    │ App calls             │          │
    │ setsockopt(SO_RCVBUF)?│          │
    └────┬────────────┬─────┘          │
         │ YES        │ NO             │
         │            │                │
    ┌────▼─────┐ ┌───▼─────────────┐   │
    │ Use app  │ │ Auto-tuning     │   │
    │ value    │ │ enabled?        │   │
    │ (capped  │ └───┬─────────────┘   │
    │ by       │     │ YES             │
    │ rmem_max)│ ┌───▼────────────┐    │
    └──────────┘ │ Buffer grows   │    │
                 │ dynamically    │    │
                 │ Range:         │    │
                 │ tcp_rmem[0] to │    │
                 │ tcp_rmem[2]    │    │
                 │ (capped by     │    │
                 │ rmem_max)      │    │
                 └────────────────┘    │
                                       │
                         ┌──────────-──▼─────────────┐
                         │ App calls                 │
                         │ setsockopt(SO_RCVBUF)?    │
                         └────┬──────────────┬───────┘
                              │ YES          │ NO
                         ┌────▼─────┐  ┌──-──▼───────┐
                         │ Use app  │  │ Keep default│
                         │ value    │  │ (rmem_      │
                         │ (capped  │  │ default)    │
                         │ by       │  │             │
                         │ rmem_max)│  │             │
                         └──────────┘  └─────────────┘

HARD CEILING FOR ALL PATHS: net.core.rmem_max
```

## What's Next

With socket buffer architecture understood, the next topics cover memory accounting and congestion control:

- **[System Memory and Kernel Accounting](04-memory-accounting.md)**: How Linux tracks network memory usage
- **[Queueing and Congestion Control](05-queueing-congestion.md)**: TCP congestion algorithms and queue management
- **[RTT-Driven Buffer Sizing](07-rtt-buffer-sizing.md)**: Calculating optimal buffers based on BDP

---

**Previous**: [Hardware and Link-Layer Boundaries](02-hardware-link-layer.md)  
**Next**: [System Memory and Kernel Accounting](04-memory-accounting.md)
