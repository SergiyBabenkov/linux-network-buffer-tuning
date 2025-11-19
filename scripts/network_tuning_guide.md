# Network Buffer Tuning Guide

## Understanding the Dependencies

### 1. Core Buffer Hierarchy
```
┌─────────────────────────────────────────────────┐
│  HARD CEILING (applies to ALL sockets)          │
│  net.core.rmem_max / net.core.wmem_max          │
│  ├─ Limits setsockopt(SO_RCVBUF/SO_SNDBUF)      │
│  └─ Limits TCP auto-tuning maximum              │
└────────────┬────────────────────────────────────┘
             │
             ├─ TCP Sockets
             │  └─ net.ipv4.tcp_rmem / tcp_wmem
             │     ├─ [0]: minimum (always allocated)
             │     ├─ [1]: default (initial size)
             │     └─ [2]: maximum (with auto-tuning)
             │            └─ MUST BE <= rmem_max
             │
             └─ Non-TCP Sockets (UDP, RAW, etc.)
                └─ net.core.rmem_default (no auto-tuning)
```

### 2. Critical Relationships

**Rule #1: rmem_max >= tcp_rmem[2]**
```bash
# BAD - auto-tuning limited!
net.core.rmem_max = 2097152        # 2MB
net.ipv4.tcp_rmem = "4096 87380 8388608"  # max 8MB
# Result: TCP can only grow to 2MB

# GOOD - auto-tuning can reach intended max
net.core.rmem_max = 16777216       # 16MB
net.ipv4.tcp_rmem = "4096 87380 8388608"  # max 8MB
# Result: TCP can grow to 8MB, with headroom
```

**Rule #2: Window Scaling Required for Buffers > 64KB**
```bash
# Required if tcp_rmem[2] or tcp_wmem[2] > 65535
net.ipv4.tcp_window_scaling = 1
```

**Rule #3: Global TCP Memory Should Accommodate All Connections**
```bash
# Calculate tcp_mem based on expected connections
# Example: 10,000 connections × 16MB average = 160GB

# tcp_mem in pages (4KB)
# low      = 3% of RAM
# pressure = 6% of RAM  
# high     = 12% of RAM
```

## Profile Recommendations Explained

The profiles below are organized by traffic pattern and network topology to match real-world deployment scenarios.

### File Transfer - Backend Profile (10Gbps+ Datacenter)

**Use Case:** High-throughput file transfers within datacenter or availability zone
**Characteristics:** Large files (MB-GB), low RTT (0.5-5ms), 10Gbps+ links

**Configuration:**
```bash
# Large buffers optimized for datacenter throughput
net.core.rmem_max = 67108864       # 64MB
net.core.wmem_max = 67108864       # 64MB
net.ipv4.tcp_rmem = "4096 131072 33554432"   # up to 32MB
net.ipv4.tcp_wmem = "4096 65536 33554432"    # up to 32MB

# Large queues to handle bursts
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 4096

# Interface settings
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
txqueuelen = 10000
ethtool -G $DEFAULT_IF rx 4096 tx 4096
```

**Why These Values:**
- **32MB buffers:** For 10Gbps link with 5ms RTT (datacenter):
  - BDP = (10 Gbps × 0.005s) / 8 = 6.25MB
  - Buffer = 4-5× BDP for burst absorption

- **Large queues:** 10Gbps = ~1.25M packets/sec at 1000 bytes
  - Deep queues absorb micro-bursts from parallel transfers

**Trade-offs:**
- ✓ Maximum throughput within datacenter
- ✓ Handles multiple simultaneous file transfers
- ✗ Not optimized for latency-sensitive traffic
- ✗ High memory usage per connection

### Message Delivery - Backend Profile (Datacenter Low-Latency)

**Use Case:** Low-latency message delivery between backend services within datacenter/AZ
**Characteristics:** Small messages (1-5KB), low RTT (0.5-5ms), latency-critical

**Configuration:**
```bash
# Small buffers to minimize queuing delay
net.core.rmem_max = 2097152        # 2MB
net.core.wmem_max = 2097152        # 2MB
net.ipv4.tcp_rmem = "4096 65536 524288"     # up to 512KB
net.ipv4.tcp_wmem = "4096 16384 524288"     # up to 512KB

# Small queues for minimal latency
net.core.netdev_max_backlog = 3000
txqueuelen = 500

# Fast qdisc with minimal queuing
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tc qdisc replace dev $DEFAULT_IF root fq_codel target 2ms interval 50ms
```

**Why These Values:**
- **512KB buffers:** Sized for low-latency datacenter links
  - 1Gbps × 2ms RTT = 250KB BDP
  - 2× BDP provides headroom without excessive queuing

- **Minimal queues:** Reduce packet waiting time
  - Small messages benefit from immediate transmission

- **fq_codel tuning:** Aggressive queuing control
  - 2ms target minimizes standing queue
  - Fair queuing prevents head-of-line blocking

**Additional Tuning:**
```bash
# Reduce interrupt coalescing for lower latency
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ethtool -C $DEFAULT_IF rx-usecs 10 rx-frames 4 tx-usecs 10 tx-frames 4

# TCP tuning for message delivery
sysctl -w net.ipv4.tcp_slow_start_after_idle=0  # Don't reset cwnd after idle
sysctl -w net.ipv4.tcp_notsent_lowat=16384      # Send data sooner
```

**Trade-offs:**
- ✓ Minimum latency for small messages
- ✓ Minimal data loss risk during network disruptions
- ✓ Low memory footprint per connection
- ✗ Lower throughput for large transfers
- ✗ Slightly higher CPU usage

### Message Delivery - Internet Profile (Customer-Facing)

**Use Case:** Customer-facing services accepting traffic over the Internet
**Characteristics:** Small messages (1-5KB), high/variable RTT (50-200ms), packet loss/jitter

**Configuration:**
```bash
# Medium buffers sized for Internet conditions
net.core.rmem_max = 8388608        # 8MB
net.core.wmem_max = 8388608        # 8MB
net.ipv4.tcp_rmem = "4096 87380 4194304"    # up to 4MB
net.ipv4.tcp_wmem = "4096 65536 4194304"    # up to 4MB

# Moderate queues to handle jitter
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096
txqueuelen = 2000

# Fair queuing with loss tolerance
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tc qdisc replace dev $DEFAULT_IF root fq_codel
```

**Why These Values:**
- **4MB buffers:** Sized for Internet RTT with reliability focus
  - 1Gbps × 100ms RTT = 12.5MB BDP
  - Conservative sizing (~0.3× BDP) minimizes data loss during disruptions
  - Small messages don't need full BDP

- **Moderate queues:** Handle Internet variability
  - Absorbs jitter and burst arrivals
  - Prevents drops from minor traffic spikes

**Additional Tuning:**
```bash
# Enable BBR congestion control for Internet paths
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq

# Connection resilience
sysctl -w net.ipv4.tcp_retries2=8           # More retries for unreliable paths
sysctl -w net.ipv4.tcp_keepalive_time=300   # Detect dead connections sooner
```

**Trade-offs:**
- ✓ Reliable delivery over Internet paths
- ✓ Handles packet loss and jitter gracefully
- ✓ BBR optimizes for varying bandwidth conditions
- ✗ Higher latency than datacenter profile
- ✗ Moderate memory usage

### File Transfer - WAN Profile (Cross-Region)

**Use Case:** Long-distance high-throughput file transfers between datacenters/regions
**Characteristics:** Large files (MB-GB), high RTT (10-100ms), 10Gbps+ links

**Configuration:**
```bash
# Very large buffers for long-fat networks
net.core.rmem_max = 134217728      # 128MB
net.core.wmem_max = 134217728      # 128MB
net.ipv4.tcp_rmem = "4096 131072 67108864"   # up to 64MB
net.ipv4.tcp_wmem = "4096 65536 67108864"    # up to 64MB

# Large queues for sustained throughput
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 4096
txqueuelen = 10000

# Interface settings
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ethtool -G $DEFAULT_IF rx 4096 tx 4096
```

**Why These Values:**
- **64MB buffers:** Sized for long-fat networks
  - 10Gbps × 50ms RTT = 62.5MB BDP
  - Buffer ≈ BDP for full pipe utilization

- **Large queues:** Sustain high throughput
  - Deep queues needed for 10Gbps+ speeds
  - Prevents gaps in transmission

**Additional Tuning:**
```bash
# BBR for long-distance paths
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq

# Optimize for bulk transfer
sysctl -w net.ipv4.tcp_slow_start_after_idle=0
sysctl -w net.ipv4.tcp_mtu_probing=1        # Discover path MTU
```

**Trade-offs:**
- ✓ Maximum throughput on long-distance links
- ✓ Fills high-BDP pipes efficiently
- ✗ High latency (queuing delay)
- ✗ Very high memory usage per connection
- ✗ Not suitable for latency-sensitive traffic

### Balanced Profile (General Purpose)

**Use Case:** Web servers, databases, mixed workloads

**Configuration:**
```bash
net.core.rmem_max = 33554432       # 32MB
net.core.wmem_max = 33554432       # 32MB
net.ipv4.tcp_rmem = "4096 87380 16777216"   # up to 16MB
net.ipv4.tcp_wmem = "4096 65536 16777216"   # up to 16MB

net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
txqueuelen = 5000
```

**Why These Values:**
- Good for most scenarios
- Auto-tuning handles variations
- Reasonable memory usage

## Monitoring & Validation

### Check Current Buffer Usage
```bash
# Per-connection buffer usage
ss -tm dst 10.0.0.1
# Look for: skmem:(r<actual_rmem>,rb<rmem_limit>,...)

# Global TCP memory usage
cat /proc/net/sockstat
# Look for: TCP: ... mem <pages_used>

# Calculate percentage:
# used_bytes = mem × 4096
# percent = (used_bytes / tcp_mem[high]) × 100
```

### Monitor Packet Drops
```bash
# Interface statistics
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ip -s link show $DEFAULT_IF
# Look for: RX errors, RX dropped, TX dropped

# Detailed stats
nstat -az | grep -i drop

# Per-queue drops
tc -s qdisc show dev $DEFAULT_IF
```

### Performance Testing
```bash
# TCP throughput
iperf3 -c server -t 60 -P 4

# Latency under load
sockperf ping-pong -i server -t 60

# HTTP performance
wrk -t 4 -c 100 -d 60s http://server/
```

## Common Issues & Fixes

### Issue 1: Low Throughput on High-Latency Link

**Symptoms:**
```bash
# iperf3 shows low throughput
iperf3 -c server
# [  5]   0.00-10.00  sec   100 MBytes  84.0 Mbits/sec
# Expected: 1 Gbps, Getting: 84 Mbps
```

**Diagnosis:**
```bash
# Check if window is limiting
ss -ti dst server
# Look for: cwnd, ssthresh, bytes_acked

# Check buffer settings
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
```

**Fix:**
```bash
# Calculate required buffer:
# BDP = Bandwidth × RTT
# 1 Gbps × 100ms = 12.5 MB

# Increase buffers
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.core.rmem_max=16777216
```

### Issue 2: High Latency / Bufferbloat

**Symptoms:**
```bash
# Ping shows variable latency
ping server
# 64 bytes: time=1.2ms
# 64 bytes: time=150ms  <- spike!
```

**Diagnosis:**
```bash
# Check queue depths
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tc -s qdisc show dev $DEFAULT_IF
# backlog 500000b 333p  <- large backlog!

# Check for bufferbloat
# Run: while pinging, also run iperf3
# If ping latency spikes during iperf3, you have bufferbloat
```

**Fix:**
```bash
# Use better qdisc
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tc qdisc replace dev $DEFAULT_IF root fq_codel

# Reduce buffers
sysctl -w net.ipv4.tcp_rmem="4096 65536 4194304"

# Reduce queue length
ip link set $DEFAULT_IF txqueuelen 1000
```

### Issue 3: Connection Drops Under Load

**Symptoms:**
```bash
# Logs show:
# "kernel: TCP: drop open request from X.X.X.X"
```

**Diagnosis:**
```bash
# Check SYN queue
ss -ltn | grep LISTEN
# Recv-Q is often maxed out

# Check limits
sysctl net.ipv4.tcp_max_syn_backlog
sysctl net.core.somaxconn
```

**Fix:**
```bash
sysctl -w net.ipv4.tcp_max_syn_backlog=8192
sysctl -w net.core.somaxconn=4096

# In application, increase listen backlog:
listen(sockfd, 4096);  # Not just listen(sockfd, 5)
```

### Issue 4: Memory Pressure

**Symptoms:**
```bash
# dmesg shows:
# "TCP: out of memory -- consider tuning tcp_mem"
```

**Diagnosis:**
```bash
cat /proc/net/sockstat
# TCP: inuse 5000 orphan 100 tw 500 alloc 5100 mem 450000

# Check against limit
sysctl net.ipv4.tcp_mem
# 88560  118080  177120  (in pages)

# Convert: 450000 pages × 4KB = 1.8GB
# If close to high threshold, you're in pressure
```

**Fix:**
```bash
# Increase tcp_mem
# Allocate 20% of RAM for TCP
# Example: 64GB RAM → 12GB for TCP

# 12GB = 3,145,728 pages (at 4KB/page)
sysctl -w net.ipv4.tcp_mem="786432 1572864 3145728"

# Or reduce per-socket buffers
sysctl -w net.ipv4.tcp_rmem="4096 87380 8388608"
```

## Making Changes Persistent

### Option 1: /etc/sysctl.conf
```bash
# Add to /etc/sysctl.conf
cat >> /etc/sysctl.conf << EOF
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF

# Apply
sysctl -p
```

### Option 2: /etc/sysctl.d/
```bash
# Better: separate file
cat > /etc/sysctl.d/99-network-tuning.conf << EOF
# Network performance tuning
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF

sysctl --system
```

### Option 3: Interface Settings (systemd)
```bash
# /etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
...

[Link]
TXQueueLength=10000

# Reload
systemctl restart systemd-networkd
```

## References

- Stevens, W. Richard. "UNIX Network Programming, Volume 1"
- Linux kernel documentation: Documentation/networking/
- Red Hat Performance Tuning Guide
- Cloudflare: Optimizing TCP for high WAN throughput
- Google: BBR Congestion Control
