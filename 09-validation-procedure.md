
# Common Inconsistency Patterns

## Pattern 1: "The Inverted Pyramid"

**Symptom:**
```bash
tcp_rmem = "4096 87380 16777216"     # 16MB max
rmem_max = 212992                    # 208KB
```

**Problem:**
- TCP tries to grow to 16MB
- Capped at 208KB by rmem_max
- Actual maximum is 93.75x smaller than intended!

**Visual:**
```
Intended:          |████████████████| 16MB
Actual:  |█|                          208KB
         └─────────────────────────────── Wasted capacity
```
**Detection:**
```bash
TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
RMEM_MAX=$(sysctl -n net.core.rmem_max)

if (( TCP_RMEM_MAX > RMEM_MAX )); then
    echo "INVERTED PYRAMID DETECTED!"
    echo "Effective maximum: $RMEM_MAX (not $TCP_RMEM_MAX)"
fi
```
**Fix:**
```bash
sysctl -w net.core.rmem_max=16777216
```

## Pattern 2: "The Disabled Giant"

**Symptom:**
```bash
tcp_rmem = "4096 87380 8388608"      # 8MB max
rmem_max = 16777216                  # 16MB (good!)
tcp_window_scaling = 0               # DISABLED!
```

**Problem:**
- Buffers configured for 8MB
- Window scaling disabled
- TCP window field is 16-bit = 65,535 bytes maximum (cannot exceed 2^16 - 1)
- Effective buffer: 64 KB (not 8MB!)

**Visual:**
```
Configured: |████████| 8MB
Window:     |█|
Usable:     |64KB (= 65,535 bytes maximum)
            └──── 99.2% wasted!
```
**Detection:**
```bash
TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)

if (( TCP_RMEM_MAX > 65536 )) && [[ $WINDOW_SCALING -ne 1 ]]; then
    echo "DISABLED GIANT DETECTED!"
    echo "Large buffers configured but window scaling disabled"
    echo "Effective maximum: 64KB (not $(( TCP_RMEM_MAX / 1048576 ))MB)"
fi
```
**Fix:**
```bash
sysctl -w net.ipv4.tcp_window_scaling=1
```

## Pattern 3: "The Frozen Pool"

**Symptom:**
```bash
tcp_rmem = "4096 87380 6291456"     # 6MB max
tcp_moderate_rcvbuf = 0              # Auto-tuning DISABLED
```

**Problem:**
- All connections stuck at 87,380 bytes (default)
- tcp_rmem[2] (6MB) never used
- No dynamic adaptation to network conditions

**Visual:**
```
Available: [min=4KB] [default=87KB] [max=6MB]
                          ↑
                     Stuck here forever!
```
**Detection:**
```bash
AUTO_TUNING=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)

if [[ $AUTO_TUNING -ne 1 ]]; then
    TCP_RMEM_DEF=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $2}')
    echo "FROZEN POOL DETECTED!"
    echo "All connections stuck at $TCP_RMEM_DEF bytes"
fi
```
**Fix:**
```bash
# Enable auto-tuning
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

# Also verify the default (middle value) is reasonable for your network
# If RTT > 10ms, consider increasing tcp_rmem[1] (default) too
# Example for high-latency networks:
# sysctl -w net.ipv4.tcp_rmem="4096 262144 6291456"  # Increase default from 87KB to 256KB
```

## Pattern 4: "The Overcrowded Pool"

**Symptom:**
```bash
tcp_mem = "88560 118080 177120"     # 177,120 pages = ~690MB total
tcp_rmem = "4096 87380 67108864"    # 64MB per connection
# With 20 connections at max: 20 × 64MB = 1,280MB
# Global limit: 690MB
# Deficit: 590MB!
```

**Problem:**
- Per-connection limits exceed global capacity
- System enters memory pressure early
- Connections throttled or dropped

**Visual:**
```
Global Limit:  |████████| 690MB
20 Connections:|██████████████████| 1,280MB
Overflow:           ^^^^^^ 590MB - DROPS/PRESSURE!
```
**Detection:**
```bash
PAGE_SIZE=$(getconf PAGESIZE)
TCP_MEM_HIGH=$(sysctl -n net.ipv4.tcp_mem | awk '{print $3}')
TCP_MEM_HIGH_BYTES=$(( TCP_MEM_HIGH * PAGE_SIZE ))

TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')
PER_CONN=$(( TCP_RMEM_MAX + TCP_WMEM_MAX ))

MAX_CONNS=$(( TCP_MEM_HIGH_BYTES / PER_CONN ))

echo "Maximum connections at full buffers: $MAX_CONNS"

if (( MAX_CONNS < 100 )); then
    echo "OVERCROWDED POOL DETECTED!"
    echo "Global tcp_mem too low for per-connection buffer sizes"
fi
```
**Fix:**
```bash
# Option 1: Increase global limit
TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')
NEW_TCP_MEM_HIGH=$(( TOTAL_RAM / 8 / PAGE_SIZE ))  # 12.5% of RAM

# Calculate low and pressure thresholds (standard: 25% and 50% of high)
NEW_TCP_MEM_LOW=$(( NEW_TCP_MEM_HIGH / 4 ))
NEW_TCP_MEM_PRES=$(( NEW_TCP_MEM_HIGH / 2 ))

sysctl -w net.ipv4.tcp_mem="$NEW_TCP_MEM_LOW $NEW_TCP_MEM_PRES $NEW_TCP_MEM_HIGH"

# Option 2: Reduce per-connection buffers
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"  # Reduce max to 16MB
```

## Pattern 5: "The Mismatched Twins"

**Symptom:**
```bash
net.core.rmem_default = 8388608      # 8MB
net.ipv4.tcp_rmem = "4096 131072 6291456"  # Default: 128KB
```

**Problem:**
- `rmem_default` affects UDP/RAW sockets
- `tcp_rmem[1]` affects TCP sockets
- Different defaults create confusion
- UDP gets 8MB, TCP gets 128KB!

**Visual:**
```
UDP socket:  |████████| 8MB (rmem_default)
TCP socket:  |█| 128KB (tcp_rmem[1])
             └── Inconsistent!
```
**Detection:**
```bash
RMEM_DEFAULT=$(sysctl -n net.core.rmem_default)
TCP_RMEM_DEF=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $2}')

if (( RMEM_DEFAULT != TCP_RMEM_DEF )); then
    echo "MISMATCHED TWINS DETECTED!"
    echo "UDP default: $RMEM_DEFAULT"
    echo "TCP default: $TCP_RMEM_DEF"
    echo "This may be intentional, but verify it matches your needs"
fi
```
**Fix (if unintentional):**
```bash
# Align them
sysctl -w net.core.rmem_default=131072
```

---

# Troubleshooting Guide

## Issue: Low Throughput on High-Latency Link

**Symptoms:**
- `iperf3` shows low throughput
- High bandwidth × delay product (BDP) link
- Plenty of bandwidth available

**Diagnosis Steps:**

### Calculate Required Buffer

```bash
# Example: 1 Gbps link with 100ms RTT
# BDP = Bandwidth × RTT
# BDP = 1,000,000,000 bits/sec × 0.1 sec = 100,000,000 bits = 12,500,000 bytes = ~12 MB

BANDWIDTH_MBPS=1000
RTT_MS=100

BDP_BYTES=$(( BANDWIDTH_MBPS * 125 * RTT_MS ))
echo "Required buffer: $BDP_BYTES bytes ($(( BDP_BYTES / 1048576 ))MB)"
```

### Check Current Buffer

```bash
# During transfer, check actual buffer:
ss -tm dst <remote_ip> | grep skmem

# Look at 'rb' value (receive buffer limit)
# If rb < BDP_BYTES, buffer is too small
```

### Check Limiting Factor

```bash
# Check both receive and send buffers (throughput needs both)
TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')
RMEM_MAX=$(sysctl -n net.core.rmem_max)
WMEM_MAX=$(sysctl -n net.core.wmem_max)
WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)

echo "tcp_rmem[2]: $TCP_RMEM_MAX"
echo "tcp_wmem[2]: $TCP_WMEM_MAX"
echo "rmem_max:    $RMEM_MAX"
echo "wmem_max:    $WMEM_MAX"
echo "Window scaling: $WINDOW_SCALING"

# Limiting factor for receive buffer is the smallest of:
RECV_LIMIT=$TCP_RMEM_MAX
if (( RMEM_MAX < RECV_LIMIT )); then
    RECV_LIMIT=$RMEM_MAX
    echo "Receive LIMITED BY: rmem_max"
fi
if (( WINDOW_SCALING != 1 )); then
    RECV_LIMIT=65536
    echo "Receive LIMITED BY: window scaling disabled"
fi

# Limiting factor for send buffer is the smallest of:
SEND_LIMIT=$TCP_WMEM_MAX
if (( WMEM_MAX < SEND_LIMIT )); then
    SEND_LIMIT=$WMEM_MAX
    echo "Send LIMITED BY: wmem_max"
fi

echo "Effective recv limit: $RECV_LIMIT bytes"
echo "Effective send limit: $SEND_LIMIT bytes"
echo "Required buffer: $BDP_BYTES bytes"

if (( RECV_LIMIT < BDP_BYTES )) || (( SEND_LIMIT < BDP_BYTES )); then
    echo "❌ Buffer too small for this link!"
fi
```

**Fix:**

```bash
# Set buffer to 2x BDP for safety
REQUIRED_BUFFER=$(( BDP_BYTES * 2 ))

# Fix rmem_max first (must be >= tcp_rmem[2])
sysctl -w net.core.rmem_max=$REQUIRED_BUFFER
sysctl -w net.core.wmem_max=$REQUIRED_BUFFER

# Then set TCP buffers
sysctl -w net.ipv4.tcp_rmem="4096 87380 $REQUIRED_BUFFER"
sysctl -w net.ipv4.tcp_wmem="4096 65536 $REQUIRED_BUFFER"

# Ensure window scaling is enabled
sysctl -w net.ipv4.tcp_window_scaling=1

# Ensure auto-tuning is enabled
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
```

## Issue: Connection Drops Under Load

**Symptoms:**
- `dmesg` shows: "TCP: drop open request"
- Connections fail during high load
- `netstat -s` shows ListenDrops increasing

**Diagnosis:**

```bash
# 1. Check listen queue
ss -ltn | grep LISTEN
# Look at Recv-Q (should be << Send-Q)
# High Recv-Q means connections are queuing and being dropped

# 2. Check limits
SOMAXCONN=$(sysctl -n net.core.somaxconn)
TCP_MAX_SYN_BACKLOG=$(sysctl -n net.ipv4.tcp_max_syn_backlog)

echo "somaxconn: $SOMAXCONN"
echo "tcp_max_syn_backlog: $TCP_MAX_SYN_BACKLOG"

# 3. Check application's listen() call
# Use strace on the application:
# strace -e listen <application>
# Look for: listen(3, <backlog>)
# If backlog < somaxconn, app is limiting itself

# 4. Monitor drops in real-time
echo "Initial state:"
netstat -s | grep -i "listen\|syn"

sleep 5

echo "After 5 seconds:"
netstat -s | grep -i "listen\|syn"
# If numbers increasing, you have drops

# 5. Check SYN-specific drops (more informative)
# Look for these specific metrics:
netstat -s | grep -E "(SYN|Listen|Conns)"
# Key metrics:
# - "SYN cookies sent/received" = SYN flood handling
# - "ListenOverflows" = Listen backlog exceeded
# - "ListenDrops" = Connections dropped from backlog

# 6. Check if system is hitting kernel limits
# These values are hard limits even if somaxconn is higher
cat /proc/sys/net/ipv4/tcp_max_syn_backlog
cat /proc/sys/net/core/somaxconn
```

**Fix:**

```bash
# 1. Increase system limits
sysctl -w net.core.somaxconn=4096
sysctl -w net.ipv4.tcp_max_syn_backlog=8192

# 2. Check application configuration
# Many apps have their own config:
# - Nginx: listen ... backlog=4096;
# - Apache: ListenBacklog 4096
# - Node.js: server.listen(port, hostname, backlog)

# 3. Make persistent
echo "net.core.somaxconn = 4096" >> /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog = 8192" >> /etc/sysctl.conf
```

## Issue: Memory Pressure / Out of Memory

**Symptoms:**
- `dmesg` shows: "TCP: out of memory"
- `cat /proc/net/sockstat` shows mem close to tcp_mem[2]
- Connections slow or fail

**Diagnosis:**

```bash
# 1. Check current TCP memory usage
PAGE_SIZE=$(getconf PAGESIZE)
TCP_MEM=$(sysctl -n net.ipv4.tcp_mem)
read TCP_MEM_LOW TCP_MEM_PRES TCP_MEM_HIGH <<< "$TCP_MEM"

CURRENT_MEM=$(awk '/^TCP:/{print $NF}' /proc/net/sockstat)

echo "TCP memory (pages):"
echo "  Low:      $TCP_MEM_LOW"
echo "  Pressure: $TCP_MEM_PRES"
echo "  High:     $TCP_MEM_HIGH"
echo "  Current:  $CURRENT_MEM"

CURRENT_BYTES=$(( CURRENT_MEM * PAGE_SIZE ))
HIGH_BYTES=$(( TCP_MEM_HIGH * PAGE_SIZE ))
PERCENT=$(( CURRENT_BYTES * 100 / HIGH_BYTES ))

echo ""
echo "Current usage: $(numfmt --to=iec $CURRENT_BYTES) / $(numfmt --to=iec $HIGH_BYTES) (${PERCENT}%)"

# 2. Calculate per-connection average
CONNS=$(ss -tan | grep ESTAB | wc -l)
if (( CONNS > 0 )); then
    AVG_PER_CONN=$(( CURRENT_BYTES / CONNS ))
    echo "Average per connection: $(numfmt --to=iec $AVG_PER_CONN)"
fi

# 3. Check if approaching limit
if (( PERCENT > 80 )); then
    echo "❌ CRITICAL: TCP memory usage >80%!"
elif (( PERCENT > 50 )); then
    echo "⚠️  WARNING: TCP memory usage >50%"
fi
```

**Fix:**

```bash
# Option 1: Increase tcp_mem (if you have RAM)
# Formula: tcp_mem[high] = RAM × percentage / PAGE_SIZE
# - 12.5% (default): Conservative, safe for most workloads
# - 25%: Moderate, allows more TCP memory
# - 50%: Aggressive, risky if other services need RAM
#
# Consider your workload:
# - 100 connections × 16MB = 1.6GB needed at high pressure
# - Calculate required high threshold for your connection count
#
# Example calculation:
# EXPECTED_CONNS=1000
# BUFFER_PER_CONN=16777216  # 16MB
# REQUIRED_TOTAL=$(( EXPECTED_CONNS * BUFFER_PER_CONN ))

TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')
PAGE_SIZE=$(getconf PAGESIZE)

# Start with 12.5% if you're not sure
NEW_HIGH=$(( TOTAL_RAM / 8 / PAGE_SIZE ))  # 12.5% of RAM

# Thresholds follow standard ratio (25% and 50% of high)
NEW_LOW=$(( NEW_HIGH / 4 ))
NEW_PRES=$(( NEW_HIGH / 2 ))

sysctl -w net.ipv4.tcp_mem="$NEW_LOW $NEW_PRES $NEW_HIGH"

# Option 2: Reduce per-socket buffers
# This allows more concurrent connections within the same tcp_mem limit
sysctl -w net.ipv4.tcp_rmem="4096 87380 8388608"   # Reduce max to 8MB
sysctl -w net.ipv4.tcp_wmem="4096 65536 8388608"

# Option 3: Reduce connection timeout (free memory faster)
sysctl -w net.ipv4.tcp_fin_timeout=30      # Default: 60
sysctl -w net.ipv4.tcp_tw_reuse=1          # Reuse TIME_WAIT sockets

# Option 4: Verify window scaling is enabled (large buffers need this)
sysctl -w net.ipv4.tcp_window_scaling=1
```