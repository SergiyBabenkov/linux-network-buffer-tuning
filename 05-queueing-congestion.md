# Queueing and Congestion Control

## Overview

Network queues exist at multiple points in the data path, and each queue introduces potential latency through buffering. Understanding where packets queue, why queues exist, and how to configure them appropriately is essential for optimizing both latency and throughput based on application requirements.

This document explores TCP congestion control algorithms, Linux queueing disciplines (qdiscs), Active Queue Management (AQM), and practical configuration strategies for achieving consistent low-latency performance on RHEL/OEL 8.

## Why Queues Exist

### The Fundamental Problem

Networks are bursty. Traffic arrives in bursts that exceed instantaneous link capacity, requiring buffering to prevent packet loss.

```
┌─────────────────────────────────────────────────────────────────┐
│ THE QUEUING NECESSITY                                           │
│                                                                 │
│ Without Queues:                                                 │
│                                                                 │
│ Traffic Arrival:  ████████  ██  ████  ██████████                │
│ Link Capacity:    ──────────────────────────────────            │
│ Result:           ████████  ██  ████  ██DROP█████  ← Packet loss│
│                                                                 │
│ With Queues:                                                    │
│                                                                 │
│ Traffic Arrival:  ████████  ██  ████  ██████████                │
│                     ↓                    ↓                      │
│ Queue:            [████]              [██████]                  │
│                     ↓                    ↓                      │
│ Link Capacity:    ████████──██──████────██████████              │
│ Result:           Smooth transmission, no loss (if queue big)   │
│                   But: Added latency while waiting in queue     │
└─────────────────────────────────────────────────────────────────┘
```

**Trade-off**:
- **No queue**: Low latency when link is idle, but packet loss during bursts
- **Large queue**: No loss during bursts, but high latency when queue is full
- **Optimal queue**: Just enough buffering to handle normal bursts, minimal latency

### Where Packets Queue

Packets can queue at multiple locations in the network stack:

```
┌─────────────────────────────────────────────────────────────────┐
│ QUEUING POINTS IN THE DATA PATH                                 │
│                                                                 │
│ Application                                                     │
│    ↓                                                            │
│ ┌─────────────────────────┐                                     │
│ │ Socket Send Buffer      │ ← Queue 1: Application-level        │
│ │ (SO_SNDBUF)             │    Controlled by buffer size        │
│ └─────────────────────────┘    Latency: Depends on ACKs         │
│    ↓                                                            │
│ ┌─────────────────────────┐                                     │
│ │ TCP Output Queue        │ ← Queue 2: TCP layer                │
│ │ (Segmented packets)     │    Waiting for transmission         │
│ └─────────────────────────┘    Latency: Microseconds            │
│    ↓                                                            │
│ ┌─────────────────────────┐                                     │
│ │ Queueing Discipline     │ ← Queue 3: Traffic control          │
│ │ (qdisc: fq_codel, etc.) │    Packet scheduling                │
│ └─────────────────────────┘    Latency: Varies by load          │
│    ↓                                                            │
│ ┌─────────────────────────┐                                     │
│ │ NIC Driver Ring Buffer  │ ← Queue 4: Hardware interface       │
│ │ (TX ring)               │    DMA queue                        │
│ └─────────────────────────┘    Latency: Microseconds            │
│    ↓                                                            │
│ ┌─────────────────────────┐                                     │
│ │ Physical Wire           │    Serialization + propagation      │
│ └─────────────────────────┘    Latency: Physics (speed of light)│
│    ↓                                                            │
│ [Router/Switch Queues]     ← Queue 5+: Network equipment        │
│    ↓                           Each hop adds latency            │
│ Destination                                                     │
└─────────────────────────────────────────────────────────────────┘
```

**For low-latency systems**: Focus on Queues 1, 3, and 4 (controllable on local system).

## TCP Congestion Control

### What Is Congestion Control?

TCP congestion control prevents senders from overwhelming the network. It dynamically adjusts the sending rate based on perceived network conditions.

**Key Concepts**:

```
Congestion Window (cwnd):
  - Maximum amount of unacknowledged data TCP will send
  - Starts small (initial window)
  - Grows when network is healthy (no loss)
  - Shrinks when congestion detected (loss or delay)

Flow Control Window (rwnd):
  - Advertised by receiver (based on SO_RCVBUF)
  - Prevents overwhelming receiver
  - Independent of congestion control

Effective Window = min(cwnd, rwnd)
```

### Congestion Control States

TCP congestion control operates in different states:

```
┌─────────────────────────────────────────────────────────────────┐
│ TCP CONGESTION CONTROL STATE MACHINE                            │
│                                                                 │
│ Connection Start:                                               │
│ ┌──────────────────┐                                            │
│ │  Slow Start      │  cwnd grows exponentially                  │
│ │  cwnd += MSS     │  Doubles every RTT                         │
│ │  per ACK         │  Fast ramp-up                              │
│ └──────────────────┘                                            │
│         │                                                       │
│         │ cwnd reaches ssthresh (slow start threshold)          │
│         ▼                                                       │
│ ┌──────────────────┐                                            │
│ │ Congestion       │  cwnd grows linearly                       │
│ │ Avoidance        │  +1 MSS per RTT                            │
│ │                  │  Steady state operation                    │
│ └──────────────────┘                                            │
│         │                                                       │
│         │ Packet loss detected (duplicate ACKs or timeout)      │
│         ▼                                                       │
│ ┌──────────────────┐                                            │
│ │ Fast Recovery    │  Retransmit lost packet                    │
│ │ (if dup ACKs)    │  cwnd reduced (typically halved)           │
│ │                  │  Quick recovery without full restart       │
│ └──────────────────┘                                            │
│         │                                                       │
│         ├──→ Recovery successful → Congestion Avoidance         │
│         │                                                       │
│         └──→ Timeout (RTO) → Slow Start (cwnd = initial)        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Congestion Control Algorithms

Linux supports multiple congestion control algorithms, each with different characteristics:

#### Available Algorithms on RHEL/OEL 8

```bash
# List available congestion control algorithms
sysctl net.ipv4.tcp_available_congestion_control
# Output: net.ipv4.tcp_available_congestion_control = reno cubic

# Check current default
sysctl net.ipv4.tcp_congestion_control
# Output: net.ipv4.tcp_congestion_control = cubic

# List all loaded algorithms
cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

#### Algorithm Comparison

```
┌─────────────────────────────────────────────────────────────────┐
│ CONGESTION CONTROL ALGORITHM CHARACTERISTICS                    │
│                                                                 │
│ Algorithm    Year  Characteristics              Best For        │
│ ──────────────────────────────────────────────────────────────  │
│                                                                 │
│ Reno         1990  Loss-based                   Simple, stable  │
│                    Halves cwnd on loss          Legacy systems  │
│                    Additive increase                            │
│                                                                 │
│ CUBIC        2005  Loss-based                   High BDP paths  │
│ (DEFAULT)          Cubic growth function        Internet        │
│                    Fast recovery from loss      General purpose │
│                    Independent of RTT                           │
│                                                                 │
│ BBR          2016  Delay-based                  Low latency     │
│                    Measures bottleneck BW       Datacenters     │
│                    Targets min RTT              Message delivery│
│                    Paces packets                                │
│                                                                 │
│ Vegas        1994  Delay-based                  Stable paths    │
│                    Increases cwnd if RTT stable Low priority    │
│                    Decreases if RTT growing     Background      │
│                                                                 │
│ Westwood     2001  Loss-based with BW estimate  Wireless        │
│                    Better for lossy links       Mobile          │
│                                                                 │
│ HTCP         2004  Loss-based, aggressive       High-speed      │
│                    Fast convergence             Long-distance   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### CUBIC (Default Algorithm)

CUBIC is the default on RHEL/OEL 8 and works well for most scenarios:

**Characteristics**:
```
Growth Function:
  W(t) = C × (t - K)³ + W_max

Where:
  W_max = Window size when loss occurred
  K = Time to reach W_max again
  C = Constant (scales growth rate)

Behavior:
  - After loss, cwnd drops to W_max × β (typically 0.7 × W_max)
  - Grows slowly near W_max (cautious)
  - Grows fast far from W_max (aggressive)
  - Independent of RTT (fair to long-distance flows)
```

**When CUBIC Works Well**:
- Internet connections with varying RTT
- High bandwidth-delay product paths
- Mix of short and long flows
- Default choice for most scenarios

### BBR (Bottleneck Bandwidth and RTT)

BBR is Google's modern congestion control algorithm, excellent for low-latency applications:

**Key Innovation**: Instead of reacting to packet loss, BBR proactively measures:
1. **Bottleneck bandwidth** (maximum achievable throughput)
2. **Round-trip propagation time** (minimum RTT without queuing)

**Behavior**:
```
BBR Operating Model:
  1. Measure bottleneck bandwidth
     - Track delivery rate
     - Find maximum sustainable rate
  
  2. Measure minimum RTT
     - Track RTT over time windows
     - Identify RTT without queuing delay
  
  3. Set sending rate:
     Rate = Bottleneck_BW × Pacing_Gain
     cwnd = BDP + headroom
  
  4. Pace packets evenly
     - Avoid bursts
     - Smooth transmission
     - Reduce queue buildup
```

**Advantages for Low-Latency Applications**:
- Lower latency (doesn't fill queues)
- More consistent RTT
- Better performance on shallow buffers
- Works well in datacenters

**Disadvantages**:
- Can be aggressive (may need tuning)
- Requires kernel 4.9+ (RHEL/OEL 8 has it)
- May not play well with loss-based algorithms on same path

### Checking Connection's Congestion Algorithm

```bash
# View congestion control algorithm for active connections
ss -ti dst 10.0.0.5

# Output example:
# ESTAB  0  0    192.168.1.10:45678  10.0.0.5:80
#        cubic wscale:7,7 rto:204 rtt:1.5/0.75
#        ^^^^
#        Current congestion control algorithm

# See more details:
ss -ti | grep -E "cubic|bbr|reno"
```

### Changing Congestion Control Algorithm

#### System-Wide Default

```bash
# Check current default
sysctl net.ipv4.tcp_congestion_control

# Change to BBR (recommended for low latency)
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr

# Make permanent
echo "net.ipv4.tcp_congestion_control = bbr" | \
    sudo tee -a /etc/sysctl.d/99-congestion-control.conf
sudo sysctl -p /etc/sysctl.d/99-congestion-control.conf
```

#### Per-Socket (Application Level)

```c
#include <netinet/tcp.h>

int sockfd = socket(AF_INET, SOCK_STREAM, 0);

// Set congestion control algorithm to BBR
const char *algo = "bbr";
if (setsockopt(sockfd, IPPROTO_TCP, TCP_CONGESTION, 
               algo, strlen(algo)) < 0) {
    perror("setsockopt TCP_CONGESTION");
}

// Verify
char current_algo[16];
socklen_t len = sizeof(current_algo);
getsockopt(sockfd, IPPROTO_TCP, TCP_CONGESTION, 
           current_algo, &len);
printf("Congestion control: %s\n", current_algo);
```

## Queueing Disciplines (qdiscs)

### What Are Qdiscs?

Queueing disciplines (qdiscs) are the Linux kernel's traffic control subsystem. They determine:
- How packets are queued before transmission
- Which packet to transmit next (scheduling)
- When to drop packets (queue management)

```
┌─────────────────────────────────────────────────────────────────┐
│ QDISC ARCHITECTURE                                              │
│                                                                 │
│ IP Layer                                                        │
│    ↓                                                            │
│ ┌──────────────────────────────────────────────────────┐        │
│ │ Traffic Control (tc) - Queueing Discipline           │        │
│ │                                                      │        │
│ │  Ingress qdisc          Egress qdisc (default focus) │        │
│ │  (incoming)             (outgoing)                   │        │
│ │                                                      │        │
│ │  ┌────────────────────────────────────────────┐      │        │
│ │  │ Root qdisc (per interface)                 │      │        │
│ │  │                                            │      │        │
│ │  │  Examples:                                 │      │        │
│ │  │  - pfifo_fast (legacy default)             │      │        │
│ │  │  - fq_codel (modern default RHEL 8)        │      │        │
│ │  │  - fq (Fair Queue)                         │      │        │
│ │  │  - pfifo (Simple FIFO)                     │      │        │
│ │  │  - tbf (Token Bucket Filter)               │      │        │
│ │  └────────────────────────────────────────────┘      │        │
│ └──────────────────────────────────────────────────────┘        │
│    ↓                                                            │
│ NIC Driver                                                      │
└─────────────────────────────────────────────────────────────────┘
```

### Viewing Current Qdisc

```bash
# Show qdisc for all interfaces
tc qdisc show

# Output example:
# qdisc noqueue 0: dev lo root refcnt 2
# qdisc fq_codel 0: dev eth0 root refcnt 2 limit 10240p flows 1024 
#   quantum 1514 target 5.0ms interval 100.0ms memory_limit 32Mb ecn

# Detect default interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

# Show for specific interface
tc qdisc show dev $DEFAULT_IF

# Detailed statistics
tc -s qdisc show dev $DEFAULT_IF
```

### Common Qdisc Types

#### pfifo_fast (Legacy Default)

Simple priority-based FIFO queue:

```
┌─────────────────────────────────────────────────────────────────┐
│ pfifo_fast STRUCTURE                                            │
│                                                                 │
│ Three priority bands:                                           │
│ ┌──────────────┐                                                │
│ │ Band 0 (High)│ ← TOS-based priority                           │
│ │ FIFO Queue   │   Emptied first                                │
│ └──────────────┘                                                │
│ ┌──────────────┐                                                │
│ │ Band 1 (Med) │ ← Normal traffic                               │
│ │ FIFO Queue   │   Emptied if Band 0 empty                      │
│ └──────────────┘                                                │
│ ┌──────────────┐                                                │
│ │ Band 2 (Low) │ ← Bulk traffic                                 │
│ │ FIFO Queue   │   Emptied if Band 0,1 empty                    │
│ └──────────────┘                                                │
│                                                                 │
│ Issues:                                                         │
│  - No fairness between flows                                    │
│  - Can cause bufferbloat (queues too deep)                      │
│  - Single bulk flow can monopolize queue                        │
└─────────────────────────────────────────────────────────────────┘
```

**When to Use**: Legacy systems, simple setups (not recommended for new deployments)

#### fq_codel (Modern Default on RHEL 8)

Fair Queue + Controlled Delay (Active Queue Management):

```
┌────────────────────────────────────────────────────────────────┐
│ fq_codel ARCHITECTURE                                          │
│                                                                │
│ Per-Flow Fairness (fq):                                        │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│ │ Flow 1   │ │ Flow 2   │ │ Flow 3   │ │ Flow N   │            │
│ │ Queue    │ │ Queue    │ │ Queue    │ │ Queue    │            │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘            │
│      │            │            │            │                  │
│      └────────────┴────────────┴────────────┘                  │
│                    │                                           │
│                    ▼                                           │
│         Round-robin scheduling                                 │
│                    │                                           │
│                    ▼                                           │
│ CoDel (Controlled Delay) per flow:                             │
│  - Target: 5ms (configurable)                                  │
│  - Interval: 100ms                                             │
│  - Drops packets if queuing delay > target                     │
│  - Prevents bufferbloat                                        │
│                    │                                           │
│                    ▼                                           │
│                 NIC Driver                                     │
│                                                                │
│ Benefits:                                                      │
│  ✓ Fair bandwidth sharing between flows                        │
│  ✓ Low latency (5ms target)                                    │
│  ✓ Prevents bufferbloat                                        │
│  ✓ No configuration needed                                     │
│  ✓ Works well for mixed traffic                                │
└────────────────────────────────────────────────────────────────┘
```

**Configuration Parameters**:

```bash
# Detect default interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

# View current fq_codel settings
tc qdisc show dev $DEFAULT_IF

# Output:
# qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 
#   quantum 1514 target 5.0ms interval 100.0ms memory_limit 32Mb ecn
#   ^^^^^^^^^^^^ ^^^^^^^^^^^^ ^^^^^^^ ^^^^^^^^^^
#   Max packets  Flows        Target  Interval

# Parameters:
# - limit: Maximum packets in queue (10240 default)
# - flows: Number of flow queues (1024 default)
# - quantum: Bytes per flow dequeue (1514 = 1 MTU)
# - target: Target queuing delay (5ms default)
# - interval: Measurement interval (100ms default)
# - ecn: Explicit Congestion Notification enabled
```

**When to Use**: General purpose, mixed workloads, default choice for most systems

#### fq (Fair Queue - Pure)

Google's Fair Queue implementation, often paired with BBR:

```
┌─────────────────────────────────────────────────────────────────┐
│ fq (Fair Queue) CHARACTERISTICS                                 │
│                                                                 │
│ Key Features:                                                   │
│  - Per-flow fairness (like fq_codel)                            │
│  - Pacing support (essential for BBR)                           │
│  - Very low latency (microseconds)                              │
│  - Minimal buffering                                            │
│  - No AQM (relies on congestion control)                        │
│                                                                 │
│ Packet Pacing:                                                  │
│   Instead of:  ████████ (burst)                                 │
│   Sends as:    ██ ██ ██ ██ (paced)                              │
│                                                                 │
│ Best Paired With:                                               │
│   BBR congestion control                                        │
│   (BBR + fq = optimal for low latency)                          │
└─────────────────────────────────────────────────────────────────┘
```

**Configuration**:

```bash
# Replace current qdisc with fq
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
sudo tc qdisc replace dev $DEFAULT_IF root fq

# With parameters:
sudo tc qdisc replace dev $DEFAULT_IF root fq \
    pacing \
    maxrate 1gbit

# View settings:
tc qdisc show dev $DEFAULT_IF
# qdisc fq 1: root refcnt 2 limit 10000p flow_limit 100p
#   buckets 1024 orphan_mask 1023 quantum 3028b initial_quantum 15140b
#   low_rate_threshold 550Kbit refill_delay 40.0ms pacing timer_slack 10.000us
```

**When to Use**:
- Low-latency datacenters
- With BBR congestion control
- When microsecond precision matters
- Message delivery systems

#### pfifo (Simple FIFO)

Pure first-in-first-out queue, no fairness or AQM:

```bash
# Set pfifo with 100-packet limit
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
sudo tc qdisc replace dev $DEFAULT_IF root pfifo limit 100

# Very simple: packets queued in order, no intelligence
# Useful for: Testing, understanding baseline behavior
```

**When to Use**: Testing, baseline measurements, simple embedded systems

### Configuring Qdisc for Low Latency

For latency-sensitive applications, the choice depends on environment:

#### Option 1: fq_codel (Balanced Approach)

```bash
#!/bin/bash
# configure-fqcodel-lowlatency.sh
# Tune fq_codel for low latency

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

# Replace with optimized fq_codel
sudo tc qdisc replace dev $INTERFACE root fq_codel \
    limit 1000 \
    target 2ms \
    interval 50ms \
    quantum 1514 \
    ecn

# Parameters explained:
# - limit 1000: Reduce queue depth (default 10240) for lower latency
# - target 2ms: Lower target delay (default 5ms)
# - interval 50ms: Shorter measurement window (default 100ms)
# - quantum 1514: 1 MTU per dequeue
# - ecn: Enable Explicit Congestion Notification

echo "Configured fq_codel for low latency on $INTERFACE"
tc qdisc show dev $INTERFACE
```

#### Option 2: fq with BBR (Aggressive Low Latency)

```bash
#!/bin/bash
# configure-fq-bbr.sh
# Ultimate low-latency configuration

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

# Set BBR congestion control
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr

# Set fq qdisc (optimal for BBR)
sudo tc qdisc replace dev $INTERFACE root fq \
    pacing \
    maxrate 10gbit

# Enable ECN
sudo sysctl -w net.ipv4.tcp_ecn=1

# Make permanent
cat << 'EOF' | sudo tee /etc/sysctl.d/99-bbr-fq.conf
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
EOF

echo "Configured BBR + fq for ultra-low latency"
```

## Active Queue Management (AQM)

### What Is AQM?

Active Queue Management proactively drops or marks packets before queues become full, signaling congestion early.

**Traditional Tail-Drop**:
```
Queue: [====================] ← Full
New packet arrives: DROP

Problem: Queue stays full (bufferbloat)
Result: High latency for all packets
```

**AQM (e.g., CoDel)**:
```
Queue: [============        ] ← Not full, but delay > target
Monitor queuing delay
If delay > 5ms: Start dropping packets
Result: Signal congestion early, lower latency
```

### CoDel Algorithm

CoDel (Controlled Delay) is the AQM used in fq_codel:

**Operating Principle**:
```
1. Track minimum queuing delay in interval (100ms)
2. If delay > target (5ms) for entire interval:
   → Enter dropping state
   → Drop packets at increasing rate
3. If delay < target:
   → Exit dropping state
   → Normal operation

Key Insight: 
  Delay is better indicator than queue depth
  (A full queue at 10Gbps has lower delay than
   a small queue at 10Mbps)
```

### ECN (Explicit Congestion Notification)

Instead of dropping packets, mark them to signal congestion:

```
┌─────────────────────────────────────────────────────────────────┐
│ ECN OPERATION                                                   │
│                                                                 │
│ Without ECN:                                                    │
│   Congestion detected → Drop packet → Sender retransmits        │
│   Loss: At least 1 RTT penalty                                  │
│                                                                 │
│ With ECN:                                                       │
│   Congestion detected → Mark packet (set ECN bit in IP header)  │
│   → Receiver notifies sender via ACK                            │
│   → Sender reduces cwnd                                         │
│   No loss: Faster response to congestion                        │
└─────────────────────────────────────────────────────────────────┘
```

**Enabling ECN**:

```bash
# Check current ECN setting
sysctl net.ipv4.tcp_ecn
# 0 = disabled
# 1 = enable if peer supports
# 2 = always request ECN

# Enable ECN (recommended)
sudo sysctl -w net.ipv4.tcp_ecn=1

# Make permanent
echo "net.ipv4.tcp_ecn = 1" | \
    sudo tee -a /etc/sysctl.d/99-tcp-tuning.conf
```

## Queue Depth Tuning

### TX Queue Length (txqueuelen)

The interface transmit queue length determines how many packets can wait in the qdisc:

```bash
# Check current txqueuelen
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ip link show $DEFAULT_IF | grep qlen
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel ... qlen 1000
#                                                                      ^^^^^^^^^

# Change temporarily
sudo ip link set $DEFAULT_IF txqueuelen 500

# Make permanent (NetworkManager)
sudo nmcli connection modify $DEFAULT_IF ethernet.tx-queue-length 500
sudo nmcli connection down $DEFAULT_IF
sudo nmcli connection up $DEFAULT_IF
```

**Sizing Guidance**:

```
Default: 1000 packets

For low latency (message delivery):
  Reduce to 100-500 packets
  
  Why?
  - Reduces maximum queuing delay
  - 1000 packets × 1500 bytes = 1.5MB
  - At 1 Gbps: 1.5MB = 12ms queuing delay
  - At 10 Gbps: 1.5MB = 1.2ms queuing delay
  
  With 100 packets:
  - 100 × 1500 = 150KB
  - At 1 Gbps: 150KB = 1.2ms queuing delay
  - At 10 Gbps: 150KB = 0.12ms queuing delay

Trade-off:
  Smaller queue = Lower latency, but may drop during bursts
  Larger queue = Handle bursts, but higher latency
```

### NIC Ring Buffer Size

The hardware ring buffer is another queuing point:

```bash
# Check current ring buffer size
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ethtool -g $DEFAULT_IF

# Output:
# Ring parameters for eth0:
# Pre-set maximums:
# RX:             4096
# TX:             4096
# Current hardware settings:
# RX:             512
# TX:             512

# Reduce TX ring for lower latency
sudo ethtool -G $DEFAULT_IF tx 256 rx 256

# Make permanent (add to /etc/rc.local or systemd service)
```

**Sizing Guidance**:
```
Default: Often 256-512

For low latency:
  Reduce to 128-256
  Smaller ring = Less buffering = Lower latency

For high throughput:
  Increase to 1024-4096
  Larger ring = More buffering = Better burst handling
```

## Monitoring Queue Depth and Latency

### Real-Time Queue Monitoring

```bash
#!/bin/bash
# monitor-queues.sh
# Monitor qdisc queue depth and drops

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

echo "Monitoring queues on $INTERFACE (Ctrl+C to stop)"
echo ""

while true; do
    clear
    echo "===== Queue Statistics ====="
    echo ""
    
    # Get qdisc stats
    tc -s qdisc show dev $INTERFACE
    
    echo ""
    echo "===== Active Connections ====="
    ss -s | grep TCP:
    
    echo ""
    echo "===== Network Interface Stats ====="
    ip -s link show $INTERFACE | grep -A 1 "TX:"
    
    sleep 2
done
```

### Detecting Bufferbloat

**DSLReports Bufferbloat Test** (for Internet connections):
```bash
# From command line:
curl -s http://www.dslreports.com/speedtest
# Or visit in browser for full test
```

**Local Testing**:
```bash
#!/bin/bash
# test-bufferbloat.sh
# Simple bufferbloat detection

TARGET="10.0.0.5"

echo "Testing for bufferbloat to $TARGET"
echo ""

# Measure baseline RTT (unloaded)
echo "Baseline RTT (unloaded):"
ping -c 10 -q $TARGET | grep rtt

# Start large download (simulate load)
echo ""
echo "Starting background traffic..."
dd if=/dev/zero bs=1M count=1000 | nc $TARGET 9999 &
LOAD_PID=$!
sleep 2

# Measure RTT under load
echo ""
echo "RTT under load:"
ping -c 10 -q $TARGET | grep rtt

# Stop background traffic
kill $LOAD_PID 2>/dev/null

echo ""
echo "Analysis:"
echo "If RTT under load is >> baseline: Bufferbloat present"
echo "Ideal: RTT increase < 10ms"
echo "Acceptable: RTT increase < 50ms"
echo "Bufferbloat: RTT increase > 100ms"
```

## Complete Low-Latency Configuration

### Integrated Setup Script for Low-Latency Applications

```bash
#!/bin/bash
# setup-low-latency-network.sh
# Complete network optimization for latency-sensitive applications
# Target: Sub-10ms latency for request-response traffic

set -e

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

echo "===== Low-Latency Network Configuration ====="
echo ""

# 1. Set BBR congestion control
echo "[1/6] Configuring BBR congestion control..."
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
sudo sysctl -w net.ipv4.tcp_ecn=1

# 2. Set fq qdisc (optimal for BBR)
echo "[2/6] Configuring fq qdisc..."
sudo tc qdisc replace dev $INTERFACE root fq pacing

# 3. Reduce queue lengths
echo "[3/6] Optimizing queue depths..."
sudo ip link set $INTERFACE txqueuelen 500
sudo ethtool -G $INTERFACE tx 256 rx 256 2>/dev/null || \
    echo "  (NIC ring buffer adjustment not supported)"

# 4. TCP tuning
echo "[4/6] TCP parameter tuning..."
cat << 'EOF' | sudo tee /etc/sysctl.d/99-low-latency.conf
# Congestion control
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1

# Initial window
net.ipv4.tcp_slow_start_after_idle = 0

# Fast recovery
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_recovery = 1

# Window scaling
net.ipv4.tcp_window_scaling = 1

# Timestamps (for RTT measurement)
net.ipv4.tcp_timestamps = 1

# SACK (Selective ACK)
net.ipv4.tcp_sack = 1

# Reduce keepalive time for faster detection
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# Faster orphaned socket cleanup
net.ipv4.tcp_fin_timeout = 15

# Memory (from previous document)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 8388608
net.ipv4.tcp_wmem = 4096 262144 8388608
net.ipv4.tcp_mem = 524288 1048576 2097152
EOF

sudo sysctl -p /etc/sysctl.d/99-low-latency.conf

# 5. Disable unnecessary features
echo "[5/6] Disabling performance-impacting features..."
# Disable offloading that can add latency (optional, test first)
# sudo ethtool -K $INTERFACE tso off gso off

# 6. Make interface changes persistent
echo "[6/6] Making interface configuration persistent..."
cat << EOF | sudo tee /etc/systemd/system/network-tuning.service
[Unit]
Description=Network Interface Tuning for Low Latency
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'tc qdisc replace dev $INTERFACE root fq pacing'
ExecStart=/bin/bash -c 'ip link set $INTERFACE txqueuelen 500'
ExecStart=/bin/bash -c 'ethtool -G $INTERFACE tx 256 rx 256 || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable network-tuning.service
sudo systemctl start network-tuning.service

echo ""
echo "===== Configuration Complete ====="
echo ""
echo "Applied settings:"
echo "  - Congestion control: BBR"
echo "  - Qdisc: fq with pacing"
echo "  - TX queue length: 500"
echo "  - NIC ring buffers: 256 (if supported)"
echo "  - ECN: Enabled"
echo ""
echo "Verify with:"
echo "  tc qdisc show dev $INTERFACE"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo "  ss -ti | head -20"
echo ""
echo "Test latency with:"
echo "  ping -c 100 <target>"
echo "  ss -ti dst <target> | grep rtt"
```

### Verification

```bash
#!/bin/bash
# verify-low-latency-setup.sh

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

echo "===== Low-Latency Configuration Verification ====="
echo ""

echo "Congestion Control:"
sysctl net.ipv4.tcp_congestion_control
echo ""

echo "ECN:"
sysctl net.ipv4.tcp_ecn
echo ""

echo "Qdisc:"
tc qdisc show dev $INTERFACE
echo ""

echo "TX Queue Length:"
ip link show $INTERFACE | grep -o "qlen [0-9]*"
echo ""

echo "NIC Ring Buffers:"
ethtool -g $INTERFACE | grep -A 2 "Current"
echo ""

echo "Sample Connection (if active):"
ss -ti | grep -v "State" | head -5
```

## Key Takeaways

1. **Queues Are Necessary**: Buffers prevent packet loss during bursts
   - But queues add latency
   - Goal: Minimal queuing without loss

2. **Multiple Queuing Points**: Packets queue at many layers
   - Socket buffers, qdisc, NIC ring buffers, network equipment
   - Each layer must be tuned

3. **Congestion Control Matters**: Algorithm choice affects latency
   - CUBIC: Good general-purpose (default)
   - BBR: Best for low latency, datacenter environments
   - Must match qdisc: BBR works best with fq

4. **Modern Qdiscs Prevent Bufferbloat**: fq_codel and fq are superior to legacy pfifo_fast
   - fq_codel: Good default, balances fairness and latency
   - fq: Minimal buffering, optimal with BBR

5. **Queue Depth Trade-offs**: Smaller queues = lower latency but less burst tolerance
   - For latency-sensitive apps: Reduce txqueuelen to 100-500
   - Reduce NIC ring buffers to 128-256
   - Monitor for drops

6. **ECN Avoids Loss**: Explicit Congestion Notification signals congestion without dropping packets
   - Enable with net.ipv4.tcp_ecn = 1
   - Requires network equipment support

7. **Measure Results**: Configuration must be validated
   - Baseline RTT measurement
   - RTT under load (bufferbloat test)
   - Queue depth monitoring
   - Packet loss tracking

## What's Next

With queuing and congestion control understood, the next topics cover detection and optimization:

- **[Detecting Memory Pressure and Packet Loss Sources](06-detecting-issues.md)**: Diagnostic tools and techniques
- **[RTT-Driven Buffer Sizing](07-rtt-buffer-sizing.md)**: Calculating optimal buffer sizes
- **[Low-Latency System Profile](08-low-latency-profile.md)**: Complete system configuration checklist

---

**Previous**: [System Memory and Kernel Accounting](04-memory-accounting.md)  
**Next**: [Detecting Memory Pressure and Packet Loss Sources](06-detecting-issues.md)
