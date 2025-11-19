# System Memory and Kernel Accounting

## Overview

Socket buffers consume kernel memory, and the Linux kernel carefully tracks and limits network memory usage to prevent a few connections from starving the rest of the system. Understanding how the kernel accounts for network memory, when it applies backpressure, and how to configure these limits is critical for operating stable, high-performance network applications.

This document explores the kernel's network memory accounting system, TCP memory pressure mechanisms, how to monitor memory usage, and how to configure appropriate limits for different application profiles on RHEL/OEL 8.

## Kernel Memory vs User Memory

### Memory Space Separation

The Linux kernel maintains strict separation between user space memory (application allocations) and kernel space memory (system structures, buffers, etc.).

```
┌─────────────────────────────────────────────────────────────────┐
│ MEMORY LAYOUT (64-bit Linux)                                    │
│                                                                 │
│ High Addresses (0xFFFFFFFFFFFFFFFF)                             │
│ ┌───────────────────────────────────────────┐                   │
│ │ Kernel Space (Top 128TB)                  │                   │
│ │                                           │                   │
│ │ ┌─────────────────────────────────────┐   │                   │
│ │ │ Network Buffers (sk_buff, etc.)     │   │                   │
│ │ │  - Socket send/receive buffers      │   │                   │
│ │ │  - Protocol headers                 │   │                   │
│ │ │  - Queueing discipline buffers      │   │                   │
│ │ │  - Driver ring buffers              │   │                   │
│ │ └─────────────────────────────────────┘   │                   │
│ │                                           │                   │
│ │ ┌─────────────────────────────────────┐   │                   │
│ │ │ Other Kernel Structures             │   │                   │
│ │ │  - Process descriptors              │   │                   │
│ │ │  - File system cache                │   │                   │
│ │ │  - Device drivers                   │   │                   │
│ │ └─────────────────────────────────────┘   │                   │
│ └───────────────────────────────────────────┘                   │
│                                                                 │
│ ═══════════════════════════════════════════                     │
│                                                                 │
│ ┌───────────────────────────────────────────┐                   │
│ │ User Space (Bottom 128TB)                 │                   │
│ │                                           │                   │
│ │ Application Memory:                       │                   │
│ │  - Code (.text)                           │                   │
│ │  - Data (.data, .bss)                     │                   │
│ │  - Heap (malloc, new)                     │                   │
│ │  - Stack                                  │                   │
│ │  - Memory-mapped files                    │                   │
│ └───────────────────────────────────────────┘                   │
│ Low Addresses (0x0000000000000000)                              │
└─────────────────────────────────────────────────────────────────┘
```

**Key Points**:
- User space memory: Managed by applications via malloc/free
- Kernel space memory: Managed by kernel via kmalloc/kfree
- Network buffers live in kernel space
- Applications cannot directly access kernel memory
- Data must be copied between user and kernel space

### Why This Matters for Network Performance

When an application calls `write()` on a socket:
1. Data is copied from user space buffer to kernel space socket buffer (memory copy)
2. Socket buffer memory counts against kernel memory, not application memory
3. Multiple applications share a limited pool of kernel memory
4. Kernel must prevent any single application from exhausting kernel memory

## TCP Memory Accounting

### Three-Level Memory Accounting

The Linux kernel tracks TCP memory usage at three levels:

```
┌─────────────────────────────────────────────────────────────────┐
│ TCP MEMORY ACCOUNTING HIERARCHY                                 │
│                                                                 │
│ Level 1: Per-Socket Accounting                                  │
│ ┌─────────────────────────────────────────────────────────┐     │
│ │ Each TCP Socket:                                        │     │
│ │  - sk_wmem_alloc: Send buffer memory                    │     │
│ │  - sk_rmem_alloc: Receive buffer memory                 │     │
│ │  - sk_forward_alloc: Pre-allocated memory               │     │
│ │                                                         │     │
│ │ Limits:                                                 │     │
│ │  - SO_SNDBUF (send buffer limit)                        │     │
│ │  - SO_RCVBUF (receive buffer limit)                     │     │
│ └─────────────────────────────────────────────────────────┘     │
│                          │                                      │
│                          │ Rolls up to                          │
│                          ▼                                      │
│ Level 2: Protocol-Wide Accounting (All TCP Sockets)             │
│ ┌─────────────────────────────────────────────────────────┐     │
│ │ TCP Protocol Memory:                                    │     │
│ │  - Sum of all TCP socket memory usage                   │     │
│ │  - Tracked in pages (typically 4KB each)                │     │
│ │                                                         │     │
│ │ Limits: /proc/sys/net/ipv4/tcp_mem                      │     │
│ │  - Low threshold    (no pressure)                       │     │
│ │  - Pressure threshold (start reclaiming)                │     │
│ │  - High threshold   (enforce hard limits)               │     │
│ └─────────────────────────────────────────────────────────┘     │
│                          │                                      │
│                          │ Part of                              │
│                          ▼                                      │
│ Level 3: System-Wide Memory                                     │
│ ┌─────────────────────────────────────────────────────────┐     │
│ │ Total System Memory:                                    │     │
│ │  - All kernel allocations (network, fs, drivers, etc.)  │     │
│ │  - All user allocations                                 │     │
│ │  - Page cache, buffers                                  │     │
│ │                                                         │     │
│ │ Limits: Physical RAM + Swap                             │     │
│ └─────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

### Per-Socket Memory Tracking

Each socket tracks its own memory usage:

```c
struct sock {
    // Send buffer accounting
    int sk_wmem_alloc;      // Currently allocated send buffer memory
    int sk_sndbuf;          // Maximum send buffer size (SO_SNDBUF)
    
    // Receive buffer accounting
    int sk_rmem_alloc;      // Currently allocated receive buffer memory
    int sk_rcvbuf;          // Maximum receive buffer size (SO_RCVBUF)
    
    // Forward allocation (optimization)
    int sk_forward_alloc;   // Pre-allocated memory for fast allocation
    
    // Memory pressure flag
    unsigned long sk_flags; // Includes SOCK_QUEUE_SHRUNK flag
    
    // ... many other fields
};
```

**Memory Allocation Flow**:

```
Application calls write(sockfd, buf, 8192):
  ↓
Kernel allocates sk_buff structures:
  1. Check: sk_wmem_alloc + 8192 < sk_sndbuf?
     ├─ YES → Allocate from sk_forward_alloc (fast path)
     └─ NO  → Check protocol-wide limits
  
  2. Allocate memory for data
  
  3. Update sk_wmem_alloc += 8192
  
  4. If sk_forward_alloc depleted:
     → Allocate more from protocol-wide pool
     → Update tcp_memory_allocated
  
  5. Check protocol-wide pressure thresholds
```

## TCP Memory Limits: tcp_mem

### The Three Thresholds

The kernel maintains three system-wide thresholds for TCP memory usage, measured in **pages** (typically 4KB each):

```bash
cat /proc/sys/net/ipv4/tcp_mem
# Example output: 188888  251851  377776
#                 ^^^^^^  ^^^^^^  ^^^^^^^
#                 Low     Press   High

# Convert to MB (assuming 4KB pages):
# Low:  188888 pages × 4KB = 755 MB
# Press: 251851 pages × 4KB = 1007 MB
# High: 377776 pages × 4KB = 1511 MB
```

**Threshold Meanings**:

```
┌─────────────────────────────────────────────────────────────────┐
│ TCP MEMORY PRESSURE STATES                                      │
│                                                                 │
│ Memory Usage          State              Kernel Behavior        │
│ ─────────────────────────────────────────────────────────────── │
│                                                                 │
│ 0 ──────────────►   NORMAL              - No restrictions       │
│ │                                       - Allocations succeed   │
│ │                                       - Auto-tuning works     │
│ Low Threshold                                                   │
│ │                                                               │
│ ├──────────────►   NORMAL              - Still no restrictions  │
│ │                   (above low)         - Monitoring increases  │
│ │                                                               │
│ Pressure Threshold                                              │
│ │                                                               │
│ ├──────────────►   PRESSURE            - Start reclaiming       │
│ │                                       - Disable auto-tuning   │
│ │                                       - Shrink buffers        │
│ │                                       - Reduce windows        │
│ │                                                               │
│ High Threshold                                                  │
│ │                                                               │
│ └──────────────►   CRITICAL            - Enforce hard limits    │
│                                        - Drop packets           │
│                                        - Fail allocations       │
│                                        - May drop connections   │
└─────────────────────────────────────────────────────────────────┘
```

### Checking Current TCP Memory Usage

```bash
# Method 1: /proc/net/sockstat
cat /proc/net/sockstat
# Output:
# sockets: used 500
# TCP: inuse 150 orphan 0 tw 45 alloc 180 mem 1200
#                                            ^^^^^^^^
#                                            Memory in pages

# Interpretation:
# mem 1200 = 1200 pages = 1200 × 4KB = 4.8 MB
# Compare to tcp_mem thresholds:
#   If 1200 < 188888 (low): Normal state
#   If 188888 < 1200 < 251851: Still normal
#   If 251851 < 1200 < 377776: Memory pressure
#   If 1200 > 377776: Critical state

# Method 2: System-wide network memory
cat /proc/sys/net/core/optmem_max
# Maximum ancillary buffer size per socket
```

### Memory Pressure Detection

**Kernel Log Messages**:

When TCP enters memory pressure, the kernel logs warnings:

```bash
# Check kernel logs
dmesg | grep -i "tcp.*memory"

# Typical messages:
# TCP: out of memory
# TCP: too many orphaned sockets
# TCP: memory pressure (mem=250000)
```

**Programmatic Detection**:

```bash
# Check if TCP is currently under memory pressure
cat /proc/net/protocols | awk 'NR==1 { print } $0 ~ /TCP/'
# Output:
# protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re sp bi br ha uh gp em
# MPTCPv6   2264      0       1   no       0   yes  kernel      y  n  y  y  n  y  y  y  y  y  y  y  n  n  n  y  y  y  n
# TCPv6     2616      1       1   no     272   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y
# MPTCP     2112      0       1   no       0   yes  kernel      y  n  y  y  n  y  y  y  y  y  y  y  n  n  n  y  y  y  n
# TCP       2464      2       1   no     272   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y
#                                ^^^
#                         Memory pressure flag
```

### Configuring tcp_mem

**Understanding the Calculation**:

The kernel typically sets `tcp_mem` based on available RAM:

```
Default calculation (roughly):
  Low  = RAM_in_pages / 8
  Press = RAM_in_pages / 4  
  High = RAM_in_pages / 2

Example with 8GB RAM:
  8GB = 8192 MB = 2,097,152 pages (4KB each)
  
  Low   = 2,097,152 / 8  = 262,144 pages (1 GB)
  Press = 2,097,152 / 4  = 524,288 pages (2 GB)
  High  = 2,097,152 / 2  = 1,048,576 pages (4 GB)
```

**Increasing TCP Memory Limits**:

```bash
# For a system dedicated to network-intensive applications
# Allow TCP to use more memory before pressure

# Example: System with 16GB RAM
# Allow TCP to use up to 8GB before critical state

# Calculate pages (assuming 4KB pages):
# Target: 8GB = 8192 MB = 2,097,152 pages

# Set thresholds:
# Low:  2 GB =  524,288 pages
# Press: 4 GB = 1,048,576 pages
# High: 8 GB = 2,097,152 pages

# Temporary (until reboot):
sudo sysctl -w net.ipv4.tcp_mem="524288 1048576 2097152"

# Permanent:
sudo vi /etc/sysctl.d/99-tcp-memory.conf
# Add:
net.ipv4.tcp_mem = 524288 1048576 2097152

# Apply:
sudo sysctl -p /etc/sysctl.d/99-tcp-memory.conf
```

**Verification**:

```bash
# Check new settings
sysctl net.ipv4.tcp_mem

# Monitor if pressure occurs
watch -n 1 'cat /proc/net/sockstat | grep mem'
```

## Per-Socket vs Protocol-Wide Limits

### Interaction Between Limits

Understanding how per-socket and protocol-wide limits interact:

```
┌─────────────────────────────────────────────────────────────────┐
│ MEMORY LIMIT INTERACTION                                        │
│                                                                 │
│ Application sets SO_SNDBUF = 256KB per socket                   │
│                    ↓                                            │
│ ┌──────────────────────────────────────────────────┐            │
│ │ Per-Socket Limit Check                           │            │
│ │                                                  │            │
│ │ Can this socket allocate 256KB?                  │            │
│ │  ✓ YES if: sk_wmem_alloc + 256KB ≤ sk_sndbuf     │            │
│ │  ✗ NO  if: Would exceed SO_SNDBUF                │            │
│ └──────────────────────────────────────────────────┘            │
│                    ↓                                            │
│ ┌──────────────────────────────────────────────────┐            │
│ │ System-Wide Limit Check                          │            │
│ │                                                  │            │
│ │ Can TCP protocol allocate more memory?           │            │
│ │  ✓ YES if: tcp_memory_allocated < tcp_mem[2]     │            │
│ │  ⚠ PRESSURE if: tcp_mem[1] < allocated < [2]     │            │
│ │  ✗ NO  if: Would exceed tcp_mem[2] (high)        │            │
│ └──────────────────────────────────────────────────┘            │
│                                                                 │
│ Example Scenario:                                               │
│  - 1000 connections                                             │
│  - Each socket has SO_SNDBUF = 256KB                            │
│  - Theoretical max: 1000 × 256KB = 256 MB                       │
│  - If tcp_mem[2] = 500 MB: All sockets can fill buffers         │
│  - If tcp_mem[2] = 100 MB: Pressure kicks in early              │
│                           Not all sockets can fill buffers      │
└─────────────────────────────────────────────────────────────────┘
```

**Real-World Example**:

```bash
# Scenario: Application server with 500 active connections
# Each connection has:
#   SO_SNDBUF = 128KB (kernel doubles to 256KB)
#   SO_RCVBUF = 128KB (kernel doubles to 256KB)

# Theoretical maximum TCP memory:
#   500 connections × (256KB + 256KB) = 256 MB
#   In pages: 256 MB / 4KB = 65,536 pages

# Check current tcp_mem:
cat /proc/sys/net/ipv4/tcp_mem
# 188888 251851 377776

# 65,536 < 188888 (low threshold)
# ✓ System is safe, no memory pressure expected

# If we had 2000 connections:
#   2000 × 512KB = 1 GB = 262,144 pages
#   262,144 > 251851 (pressure threshold)
#   ⚠ Would trigger memory pressure
```

## Memory Pressure Behavior

### What Happens Under Memory Pressure

When TCP memory usage crosses the pressure threshold (`tcp_mem[1]`):

```
┌─────────────────────────────────────────────────────────────────┐
│ MEMORY PRESSURE ACTIONS                                         │
│                                                                 │
│ 1. Disable TCP Auto-Tuning                                      │
│    - Stop dynamic buffer growth                                 │
│    - Lock buffers at current size                               │
│    - Prevents further memory allocation                         │
│                                                                 │
│ 2. Shrink Socket Buffers                                        │
│    - Reduce sk_rcvbuf for underutilized sockets                 │
│    - Advertise smaller receive window                           │
│    - Free memory from idle sockets                              │
│                                                                 │
│ 3. Drop Incoming Data                                           │
│    - If receive buffer full: drop packets                       │
│    - Rely on TCP retransmission                                 │
│    - Temporary measure to reduce memory                         │
│                                                                 │
│ 4. Increase Pressure on Applications                            │
│    - write() calls may block longer                             │
│    - Harder to get new buffer allocations                       │
│    - Encourages apps to read/consume data faster                │
│                                                                 │
│ 5. Reject New Connections (if critical)                         │
│    - If memory exceeds tcp_mem[2] (high threshold)              │
│    - SYN packets may be dropped                                 │
│    - listen() backlog may fill up                               │
└─────────────────────────────────────────────────────────────────┘
```

**Latency Impact**:

Memory pressure directly increases latency:

```
Normal State:
  write() → immediate copy to buffer → returns
  Time: ~microseconds

Memory Pressure:
  write() → wait for memory → retry → eventual copy → returns
  Time: ~milliseconds (100x - 1000x slower)

Critical State:
  write() → wait → wait → wait → may fail with ENOMEM
  Time: seconds or failure
```

### Monitoring Memory Pressure

**Real-Time Monitoring Script**:

```bash
#!/bin/bash
# monitor-tcp-memory.sh
# Monitor TCP memory usage and pressure state

while true; do
    # Get current memory usage
    MEM_CURRENT=$(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $6}')
    
    # Get thresholds
    read LOW PRESS HIGH <<< $(cat /proc/sys/net/ipv4/tcp_mem)
    
    # Calculate percentages
    PCT_LOW=$(echo "scale=1; $MEM_CURRENT * 100 / $LOW" | bc)
    PCT_PRESS=$(echo "scale=1; $MEM_CURRENT * 100 / $PRESS" | bc)
    PCT_HIGH=$(echo "scale=1; $MEM_CURRENT * 100 / $HIGH" | bc)
    
    # Determine state
    if [ $MEM_CURRENT -lt $LOW ]; then
        STATE="NORMAL (below low)"
        COLOR="\033[32m"  # Green
    elif [ $MEM_CURRENT -lt $PRESS ]; then
        STATE="NORMAL (above low)"
        COLOR="\033[32m"  # Green
    elif [ $MEM_CURRENT -lt $HIGH ]; then
        STATE="PRESSURE"
        COLOR="\033[33m"  # Yellow
    else
        STATE="CRITICAL"
        COLOR="\033[31m"  # Red
    fi
    
    # Display
    clear
    echo "===== TCP Memory Monitor ====="
    echo ""
    echo -e "State: ${COLOR}${STATE}\033[0m"
    echo ""
    echo "Current Usage: $MEM_CURRENT pages"
    echo "  Low threshold:  $LOW pages ($PCT_LOW% of low)"
    echo "  Press threshold: $PRESS pages ($PCT_PRESS% of pressure)"
    echo "  High threshold: $HIGH pages ($PCT_HIGH% of high)"
    echo ""
    echo "Active TCP connections: $(ss -s | grep TCP: | awk '{print $2}')"
    echo ""
    echo "Press Ctrl+C to exit"
    
    sleep 2
done
```

**Usage**:

```bash
chmod +x monitor-tcp-memory.sh
./monitor-tcp-memory.sh
```

## Connection-Level Memory Management

### Orphaned Sockets

TCP sockets can become "orphaned" when the application closes the socket but TCP still has unacknowledged data:

```
Application closes socket:
  ↓
close(sockfd)
  ↓
Socket enters FIN-WAIT-1/FIN-WAIT-2/CLOSING state
  ↓
Still has data in send buffer waiting for ACK
  ↓
Socket becomes "orphaned"
  ↓
Kernel maintains socket until:
  - All data acknowledged, OR
  - Timeout expires (tcp_fin_timeout)
```

**Orphaned Socket Limits**:

```bash
# Maximum number of orphaned sockets
cat /proc/sys/net/ipv4/tcp_max_orphans
# Default: Typically based on available memory

# Check current orphaned count
cat /proc/net/sockstat | grep orphan
# TCP: inuse 150 orphan 5 tw 45 alloc 180 mem 1200
#                    ^^^^^^^^
#                    Currently orphaned

# If orphaned count exceeds limit:
# - Kernel aggressively closes old connections
# - May reset connections immediately
# - WARNING: "too many orphaned sockets" in dmesg
```

**Configuration**:

```bash
# Increase orphaned socket limit (if needed)
# Default formula: Available_RAM / 64KB / 2

# For 8GB system:
# Default: 8GB / 64KB / 2 = 65,536 sockets

# Set higher limit:
sudo sysctl -w net.ipv4.tcp_max_orphans=131072

# Reduce FIN-WAIT timeout (faster cleanup)
sudo sysctl -w net.ipv4.tcp_fin_timeout=30
# Default: 60 seconds
# Recommended for high-volume: 15-30 seconds
```

### TIME-WAIT Sockets

TIME-WAIT sockets also consume kernel memory (though less than active connections):

```bash
# Check TIME-WAIT count
ss -tan | grep TIME-WAIT | wc -l

# Or from sockstat:
cat /proc/net/sockstat | grep tw
# TCP: inuse 150 orphan 5 tw 45 alloc 180 mem 1200
#                           ^^^^
#                           TIME-WAIT count

# TIME-WAIT duration (typically 2× MSL = 60-120 seconds)
cat /proc/sys/net/ipv4/tcp_fin_timeout
```

**TIME-WAIT Recycling** (use with caution):

```bash
# Allow reuse of TIME-WAIT sockets for new connections
# ONLY safe for clients making outbound connections
sudo sysctl -w net.ipv4.tcp_tw_reuse=1

# NOTE: tcp_tw_recycle was removed in Linux 4.12
# Do NOT use tcp_tw_recycle (causes problems with NAT)
```

## Memory Accounting for Other Protocols

### UDP Memory Limits

UDP also has memory limits, though simpler than TCP:

```bash
# UDP memory limits (in pages)
cat /proc/sys/net/ipv4/udp_mem
# 188889  251852  377778

# Current UDP memory usage
cat /proc/net/sockstat
# UDP: inuse 45 mem 12
#              ^^^^^^
#              Memory in pages

# Per-socket UDP buffer limits
cat /proc/sys/net/core/rmem_default  # Default receive
cat /proc/sys/net/core/wmem_default  # Default send
```

### Socket Memory Totals

```bash
# Total socket memory usage (all protocols)
cat /proc/net/sockstat
# Output:
# sockets: used 500
# TCP: inuse 150 orphan 5 tw 45 alloc 180 mem 1200
# UDP: inuse 45 mem 12
# UDPLITE: inuse 0
# RAW: inuse 0
# FRAG: inuse 0 memory 0

# Interpretation:
# sockets used 500: Total sockets of all types
# TCP mem 1200: TCP using 1200 pages (4.8 MB)
# UDP mem 12: UDP using 12 pages (48 KB)
```

## Practical Configuration Examples

### Recommended Settings for RHEL/OEL 8

For a dedicated application server with 16GB RAM:

```bash
#!/bin/bash
# configure-tcp-memory.sh
# Optimize TCP memory for network applications

cat << 'EOF' | sudo tee /etc/sysctl.d/99-tcp-memory-tuning.conf
# TCP Memory Tuning for Application Server
# System: 16GB RAM

# Per-socket buffer limits
# Allow up to 16MB per socket buffer
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# TCP auto-tuning ranges (min, default, max in bytes)
# Min: 4KB (below this is problematic)
# Default: 256KB (good for typical message sizes)
# Max: 8MB (for larger transfers)
net.ipv4.tcp_rmem = 4096 262144 8388608
net.ipv4.tcp_wmem = 4096 262144 8388608

# Protocol-wide TCP memory (in pages, 4KB each)
# Allow TCP to use up to 8GB total
# Low:    2GB = 524,288 pages
# Press:  4GB = 1,048,576 pages
# High:   8GB = 2,097,152 pages
net.ipv4.tcp_mem = 524288 1048576 2097152

# Keep auto-tuning enabled
net.ipv4.tcp_moderate_rcvbuf = 1

# Orphaned socket management
# Allow more orphaned sockets (up to 131K)
net.ipv4.tcp_max_orphans = 131072

# Reduce TIME-WAIT duration for faster resource reclaim
net.ipv4.tcp_fin_timeout = 30

# Allow TIME-WAIT reuse for client connections
net.ipv4.tcp_tw_reuse = 1

# Socket buffer memory for all protocols
# Option memory limit per socket
net.core.optmem_max = 65536
EOF

# Apply settings
sudo sysctl -p /etc/sysctl.d/99-tcp-memory-tuning.conf

echo "TCP memory tuning applied successfully"
echo "Current TCP memory usage:"
cat /proc/net/sockstat | grep TCP
```

### Verification Script

```bash
#!/bin/bash
# verify-tcp-memory.sh
# Verify TCP memory configuration

echo "===== TCP Memory Configuration ====="
echo ""

echo "Per-Socket Limits:"
echo "  rmem_max: $(cat /proc/sys/net/core/rmem_max) bytes ($(echo "scale=2; $(cat /proc/sys/net/core/rmem_max)/1048576" | bc) MB)"
echo "  wmem_max: $(cat /proc/sys/net/core/wmem_max) bytes ($(echo "scale=2; $(cat /proc/sys/net/core/wmem_max)/1048576" | bc) MB)"
echo ""

echo "TCP Auto-Tuning Ranges:"
echo "  tcp_rmem: $(cat /proc/sys/net/ipv4/tcp_rmem)"
echo "  tcp_wmem: $(cat /proc/sys/net/ipv4/tcp_wmem)"
echo ""

echo "Protocol-Wide TCP Memory (pages):"
TCP_MEM=$(cat /proc/sys/net/ipv4/tcp_mem)
read LOW PRESS HIGH <<< $TCP_MEM
echo "  Low:      $LOW pages ($(echo "scale=2; $LOW*4/1024" | bc) MB)"
echo "  Pressure: $PRESS pages ($(echo "scale=2; $PRESS*4/1024" | bc) MB)"
echo "  High:     $HIGH pages ($(echo "scale=2; $HIGH*4/1024" | bc) MB)"
echo ""

echo "Current Usage:"
SOCKSTAT=$(cat /proc/net/sockstat | grep "^TCP:")
echo "  $SOCKSTAT"
MEM=$(echo $SOCKSTAT | awk '{print $6}')
echo "  Memory: $MEM pages ($(echo "scale=2; $MEM*4/1024" | bc) MB)"
echo ""

# Calculate percentage of high threshold
PCT=$(echo "scale=1; $MEM * 100 / $HIGH" | bc)
echo "  Usage: $PCT% of high threshold"

if (( $(echo "$MEM < $LOW" | bc -l) )); then
    echo "  Status: ✓ NORMAL (below low threshold)"
elif (( $(echo "$MEM < $PRESS" | bc -l) )); then
    echo "  Status: ✓ NORMAL (between low and pressure)"
elif (( $(echo "$MEM < $HIGH" | bc -l) )); then
    echo "  Status: ⚠ MEMORY PRESSURE"
else
    echo "  Status: ✗ CRITICAL (exceeds high threshold)"
fi
```

## Troubleshooting Memory Issues

### Issue 1: Frequent Memory Pressure

**Symptoms**:
- `dmesg` shows "TCP: memory pressure"
- Applications experience write latency
- Connections slow down periodically

**Diagnosis**:

```bash
# Check if currently under pressure
cat /proc/net/protocols | awk 'NR==1 { print } $0 ~ /TCP/'
# Output:
# protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re sp bi br ha uh gp em
# MPTCPv6   2264      0       1   no       0   yes  kernel      y  n  y  y  n  y  y  y  y  y  y  y  n  n  n  y  y  y  n
# TCPv6     2616      1       1   no     272   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y
# MPTCP     2112      0       1   no       0   yes  kernel      y  n  y  y  n  y  y  y  y  y  y  y  n  n  n  y  y  y  n
# TCP       2464      2       1   no     272   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y
#                                ^^^
#                         Memory pressure flag
#                          Should be "no"

# Check memory usage vs thresholds
cat /proc/net/sockstat | grep mem
cat /proc/sys/net/ipv4/tcp_mem

# Check number of connections
ss -s | grep TCP:
```

**Solutions**:

1. **Increase tcp_mem thresholds** (if RAM available)
2. **Reduce per-socket buffer sizes** (if buffers too large)
3. **Close idle connections** (reduce connection count)
4. **Add more RAM** (if system consistently near limit)

### Issue 2: Memory Exhaustion

**Symptoms**:
- Cannot establish new connections
- `dmesg` shows "out of socket memory"
- Application gets `ENOMEM` errors

**Diagnosis**:

```bash
# Check if at critical threshold
cat /proc/net/sockstat

# Check orphaned sockets
ss -s | grep orphan

# Check for memory leaks
watch -n 1 'cat /proc/net/sockstat | grep TCP'
# If mem keeps growing: likely leak
```

**Solutions**:

1. **Increase tcp_mem[2]** (high threshold)
2. **Reduce tcp_max_orphans** or decrease tcp_fin_timeout (faster cleanup)
3. **Find and fix application not closing sockets**
4. **Restart leaking applications**

### Issue 3: Per-Socket Allocation Failures

**Symptoms**:
- Specific connections fail
- Others work fine
- Not under system-wide memory pressure

**Diagnosis**:

```bash
# Check per-socket limits
sysctl net.core.rmem_max net.core.wmem_max

# Check if application trying to set buffers too large
# Enable audit logging or check application code
```

**Solutions**:

1. **Increase rmem_max/wmem_max**
2. **Reduce application's SO_RCVBUF/SO_SNDBUF requests**
3. **Check for application bugs** (requesting huge buffers)

## Key Takeaways

1. **Three-Level Accounting**: Linux tracks network memory at per-socket, protocol-wide, and system-wide levels
   - Each level has its own limits
   - Limits are hierarchical (must pass all checks)

2. **tcp_mem Thresholds**: Three states determine kernel behavior
   - Below Low: Normal operation
   - Between Low-Pressure: Still normal
   - Above Pressure: Start reclaiming memory
   - Above High: Enforce hard limits, may drop connections

3. **Memory Pressure Impacts Latency**: Under pressure, operations slow dramatically
   - Normal: microseconds
   - Pressure: milliseconds  
   - Critical: seconds or failures

4. **Kernel Doubles Buffers**: Applications request size, kernel allocates 2× for bookkeeping
   - Request 128KB → Get 256KB
   - This is expected behavior

5. **Monitor Continuously**: Memory issues often appear gradually
   - Use `cat /proc/net/sockstat` for current usage
   - Compare against `tcp_mem` thresholds
   - Set up alerting for pressure states

6. **Configuration Balance**: For applications with predictable load patterns
   - Set per-socket buffers appropriate to traffic profile (64KB-16MB)
   - Set tcp_mem high enough for peak load + 50% headroom
   - Monitor actual usage, adjust as needed

7. **Orphaned Sockets**: Applications that don't close cleanly waste memory
   - Monitor orphaned count
   - Reduce tcp_fin_timeout for faster cleanup
   - Fix applications that leak sockets

## What's Next

With memory accounting understood, the next topics cover congestion control and queue management:

- **[Queueing and Congestion Control](05-queueing-congestion.md)**: TCP congestion algorithms, qdisc configuration
- **[Detecting Memory Pressure and Packet Loss Sources](06-detecting-issues.md)**: Tools and techniques for diagnosis
- **[RTT-Driven Buffer Sizing](07-rtt-buffer-sizing.md)**: Calculating optimal buffers based on BDP

---

**Previous**: [Socket Buffer Architecture](03-socket-buffer-architecture.md)  
**Next**: [Queueing and Congestion Control](05-queueing-congestion.md)
