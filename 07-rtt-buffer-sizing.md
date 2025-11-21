# RTT-Driven Buffer Sizing and BDP Calculations

## Overview

Optimal socket buffer sizing isn't guesswork - it's based on measurable network characteristics. The Bandwidth-Delay Product (BDP) provides a scientific foundation for buffer sizing, ensuring buffers are neither too small (causing throughput loss) nor too large (causing excessive latency).

This document explains how to measure Round Trip Time (RTT), calculate BDP, and use these metrics to size socket buffers appropriately for different traffic profiles (message delivery and file transfer) on RHEL/OEL 8.

## Understanding the Bandwidth-Delay Product

### What Is BDP?

The Bandwidth-Delay Product represents the amount of data "in flight" on the network at any given moment.

```
┌─────────────────────────────────────────────────────────────────┐
│ BANDWIDTH-DELAY PRODUCT VISUALIZATION                           │
│                                                                 │
│ Sender                Network "Pipe"              Receiver      │
│   │                                                  │          │
│   │ ████████████████████████████████████████████████ │          │
│   │ ◄────────────── BDP bytes ──────────────────────►│          │
│   │                                                  │          │
│   │                                                  │          │
│   │◄─────────────── RTT ────────────────────────────►│          │
│   │                                                  │          │
│   │ Send              Propagate              Receive │          │
│   │                   Process                        │          │
│   │                   Return                         │          │
│                                                                 │
│ BDP = Bandwidth × RTT                                           │
│                                                                 │
│ Example:                                                        │
│   Bandwidth = 1 Gbps = 125,000,000 bytes/sec                    │
│   RTT = 10 ms = 0.01 sec                                        │
│   BDP = 125,000,000 × 0.01 = 1,250,000 bytes = 1.22 MB          │
│                                                                 │
│ This is how much data can be "in flight" simultaneously         │
└─────────────────────────────────────────────────────────────────┘
```

**Why It Matters**:
- If socket buffer < BDP: Cannot fully utilize available bandwidth
- If socket buffer = BDP: Optimal throughput
- If socket buffer > BDP: No throughput gain, but more buffering (latency)

### The BDP Formula

```
BDP (bytes) = Bandwidth (bits/sec) × RTT (seconds) / 8

Breaking it down:
1. Convert bandwidth to bytes/sec: Bandwidth / 8
2. Multiply by RTT in seconds: (Bandwidth / 8) × RTT

Example calculations:
  1 Gbps, 1ms RTT:
    BDP = (1,000,000,000 / 8) × 0.001 = 125,000 bytes = 122 KB
  
  1 Gbps, 10ms RTT:
    BDP = (1,000,000,000 / 8) × 0.010 = 1,250,000 bytes = 1.22 MB
  
  10 Gbps, 1ms RTT:
    BDP = (10,000,000,000 / 8) × 0.001 = 1,250,000 bytes = 1.22 MB
  
  100 Mbps, 50ms RTT:
    BDP = (100,000,000 / 8) × 0.050 = 625,000 bytes = 610 KB
```

### BDP vs Buffer Size Relationship

```
┌─────────────────────────────────────────────────────────────────┐
│ BUFFER SIZING RELATIVE TO BDP                                   │
│                                                                 │
│ Buffer Size          Effect on Performance                      │
│-───────────────────────────────────────────────────-────────────│
│                                                                 │
│ < 0.5 × BDP         Severe throughput loss                      │
│                     TCP window too small                        │
│                     Link underutilized                          │
│                                                                 │
│ 0.5 - 1.0 × BDP     Suboptimal throughput                       │
│                     Occasional stalls                           │
│                     90-98% efficiency                           │
│                                                                 │
│ 1.0 × BDP           Optimal for bulk transfers                  │
│                     Full link utilization                       │
│                     Minimal unnecessary buffering               │
│                                                                 │
│ 1.0 - 2.0 × BDP     Good for variable conditions                │
│                     Handles RTT fluctuations                    │
│                     Recommended for most scenarios              │
│                                                                 │
│ 2.0 - 4.0 × BDP     High throughput, higher latency             │
│                     Good for lossy networks                     │
│                     Excessive for low-latency apps              │
│                                                                 │
│ > 4.0 × BDP         Bufferbloat territory                       │
│                     Excessive queuing delay                     │
│                     Not recommended                             │
└─────────────────────────────────────────────────────────────────┘
```

## Measuring RTT

### Method 1: Using ping

```bash
# Basic RTT measurement
ping -c 100 10.0.0.5

# Output:
# --- 10.0.0.5 ping statistics ---
# 100 packets transmitted, 100 received, 0% packet loss, time 99122ms
# rtt min/avg/max/mdev = 1.234/1.456/2.345/0.123 ms
#         ^^^  ^^^  ^^^  ^^^
#         Min  Avg  Max  Std deviation

# For accurate measurements, use larger packet size (simulate TCP)
ping -c 100 -s 1460 10.0.0.5

# Flood ping for statistics (requires root)
sudo ping -f -c 10000 10.0.0.5
```

**Interpreting Results**:
```
Good (datacenter):     RTT < 2ms, mdev < 0.5ms
Acceptable (LAN):      RTT < 10ms, mdev < 2ms
Typical (Internet):    RTT 20-100ms, mdev varies
Problem:               mdev > 50% of avg (jitter)
```

### Method 2: Using ss (TCP RTT)

```bash
# View RTT for active TCP connections
ss -ti dst 10.0.0.5

# Output:
# ESTAB  0  0    192.168.1.10:45678  10.0.0.5:80
#        cubic wscale:7,7 rto:204 rtt:1.567/0.891
#                                   ^^^^^^^^^^^
#                                   RTT avg/variance in ms

# Extract just RTT values
ss -ti dst 10.0.0.5 | grep -oP 'rtt:\K[0-9.]+/[0-9.]+'

# Monitor RTT over time
watch -n 1 'ss -ti dst 10.0.0.5 | grep rtt'

# Get RTT statistics for all connections
ss -ti | grep -oP 'rtt:\K[0-9.]+' | awk '{
    sum+=$1; sumsq+=$1*$1; n++
} END {
    if (n>0) {
        avg=sum/n
        stddev=sqrt(sumsq/n - avg*avg)
        print "RTT Statistics:"
        print "  Count: " n
        print "  Average: " avg " ms"
        print "  Std Dev: " stddev " ms"
    }
}'
```

### Method 3: Using tcpdump/tcptrace

```bash
# Capture traffic
sudo tcpdump -i eth0 -w /tmp/capture.pcap host 10.0.0.5

# Analyze with tcptrace (if available)
tcptrace -l /tmp/capture.pcap

# Or analyze manually for SYN/SYN-ACK timing
tshark -r /tmp/capture.pcap -Y "tcp.flags.syn==1" -T fields \
    -e frame.time_relative -e tcp.flags

# Calculate RTT from three-way handshake:
# Time(SYN-ACK) - Time(SYN) = RTT/2 (approximately)
```

### Method 4: Application-Level Measurement

For accurate application-level RTT:

```bash
# Using curl with timing
curl -w "@curl-format.txt" -o /dev/null -s http://10.0.0.5/test

# Create curl-format.txt:
cat > curl-format.txt << 'EOF'
    time_namelookup:  %{time_namelookup}s
       time_connect:  %{time_connect}s
    time_appconnect:  %{time_appconnect}s
   time_pretransfer:  %{time_pretransfer}s
      time_redirect:  %{time_redirect}s
 time_starttransfer:  %{time_starttransfer}s
                    ----------
         time_total:  %{time_total}s
EOF

# RTT ≈ time_connect (for TCP handshake)
```

### RTT Measurement Script

```bash
#!/bin/bash
# measure-rtt.sh
# Comprehensive RTT measurement to target host

# Check dependencies
check_dependencies() {
    local missing_deps=()

    # Required tools
    command -v ping &> /dev/null || missing_deps+=("iputils")
    command -v ss &> /dev/null || missing_deps+=("iproute")
    command -v awk &> /dev/null || missing_deps+=("gawk")

    # Optional tools
    local optional_missing=()
    command -v hping3 &> /dev/null || optional_missing+=("hping3")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi

    if [ ${#optional_missing[@]} -gt 0 ]; then
        echo "INFO: Optional tools not found: ${optional_missing[*]}"
        echo "      Some measurements will be skipped"
        echo ""
    fi
}

check_dependencies

TARGET="$1"
if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target_host>"
    exit 1
fi

echo "===== RTT Measurement to $TARGET ====="
echo ""

# Method 1: ICMP ping
echo "[1] ICMP Ping (100 packets):"
ping -c 100 -q "$TARGET" 2>/dev/null | grep rtt
echo ""

# Method 2: TCP ping (if hping3 available)
if command -v hping3 &> /dev/null; then
    echo "[2] TCP Ping (SYN to port 80):"
    sudo hping3 -S -p 80 -c 10 "$TARGET" 2>&1 | grep "rtt=" | \
        awk '{print $7}' | sed 's/rtt=//' | awk '{
            sum+=$1; n++
        } END {
            print "  Average RTT: " sum/n " ms"
        }'
    echo ""
fi

# Method 3: Active TCP connections (if any)
echo "[3] Active TCP Connection RTT:"
if ss -ti dst "$TARGET" 2>/dev/null | grep -q rtt; then
    ss -ti dst "$TARGET" | grep rtt | head -5
else
    echo "  No active connections to $TARGET"
fi
echo ""

# Method 4: Establish test connection and measure
echo "[4] Test TCP Connection:"
(
    # Use bash TCP redirection for quick test
    time bash -c "exec 3<>/dev/tcp/$TARGET/80 && echo -e 'HEAD / HTTP/1.0\r\n\r\n' >&3"
) 2>&1 | grep real | awk '{print "  Connection establishment: " $2}'

echo ""
echo "===== Summary ====="
echo "Use the lowest consistent value for BDP calculations"
```

## Calculating Buffer Size from BDP

### Basic BDP Calculation Script

```bash
#!/bin/bash
# calculate-bdp.sh
# Calculate optimal buffer size based on BDP

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v awk &> /dev/null || missing_deps+=("gawk")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

# Function to calculate BDP
calculate_bdp() {
    local bandwidth_gbps=$1
    local rtt_ms=$2

    # Use awk for all calculations (more portable than bc)
    awk -v bw="$bandwidth_gbps" -v rtt="$rtt_ms" '
    BEGIN {
        # Convert to base units
        bandwidth_bps = bw * 1000000000
        rtt_sec = rtt / 1000

        # Calculate BDP in bytes
        bdp_bytes = int(bandwidth_bps * rtt_sec / 8)

        # Convert to KB and MB for readability
        bdp_kb = bdp_bytes / 1024
        bdp_mb = bdp_bytes / 1024 / 1024

        printf "Bandwidth: %.1f Gbps\n", bw
        printf "RTT: %.1f ms\n", rtt
        printf "BDP: %d bytes (%.2f KB, %.2f MB)\n", bdp_bytes, bdp_kb, bdp_mb
    }'
}

# Interactive mode
if [ $# -eq 0 ]; then
    echo "===== BDP Calculator ====="
    echo ""
    read -p "Enter bandwidth in Gbps (e.g., 1, 10): " BW
    read -p "Enter RTT in milliseconds (e.g., 2, 10, 50): " RTT
    echo ""
    calculate_bdp "$BW" "$RTT"
else
    calculate_bdp "$1" "$2"
fi
```

### Enhanced Buffer Sizing Calculator

```bash
#!/bin/bash
# buffer-calculator.sh
# Calculate optimal socket buffer sizes with recommendations

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v awk &> /dev/null || missing_deps+=("gawk")
    command -v printf &> /dev/null || missing_deps+=("coreutils")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

calculate_buffer_size() {
    local bandwidth_gbps=$1
    local rtt_ms=$2
    local scenario=$3

    # Use awk for all calculations (more portable than bc)
    awk -v bw="$bandwidth_gbps" -v rtt="$rtt_ms" -v scen="$scenario" '
    BEGIN {
        # Calculate base BDP
        bandwidth_bps = bw * 1000000000
        rtt_sec = rtt / 1000
        bdp_bytes = int(bandwidth_bps * rtt_sec / 8)
        bdp_kb = bdp_bytes / 1024

        print "===== Buffer Size Calculation ====="
        print ""
        print "Network Parameters:"
        printf "  Bandwidth: %.1f Gbps\n", bw
        printf "  RTT: %.1f ms\n", rtt
        printf "  BDP: %d bytes (%.2f KB)\n", bdp_bytes, bdp_kb
        print ""

        # Calculate recommended buffer sizes based on scenario
        if (scen == "low-latency") {
            # For low-latency: 1.0-1.5x BDP
            min_buf = int(bdp_bytes * 1.0)
            rec_buf = int(bdp_bytes * 1.5)
            max_buf = int(bdp_bytes * 2.0)

            print "Scenario: Low-Latency (Message Delivery)"
            printf "  Minimum: %d bytes (%d KB)\n", min_buf, int(min_buf/1024)
            printf "  Recommended: %d bytes (%d KB)\n", rec_buf, int(rec_buf/1024)
            printf "  Maximum: %d bytes (%d KB)\n", max_buf, int(max_buf/1024)
        }
        else if (scen == "balanced") {
            # For balanced: 1.5-2.5x BDP
            min_buf = int(bdp_bytes * 1.5)
            rec_buf = int(bdp_bytes * 2.0)
            max_buf = int(bdp_bytes * 3.0)

            print "Scenario: Balanced (General Purpose)"
            printf "  Minimum: %d bytes (%d KB)\n", min_buf, int(min_buf/1024)
            printf "  Recommended: %d bytes (%d KB)\n", rec_buf, int(rec_buf/1024)
            printf "  Maximum: %d bytes (%d KB)\n", max_buf, int(max_buf/1024)
        }
        else if (scen == "throughput") {
            # For throughput: 2.0-4.0x BDP
            min_buf = int(bdp_bytes * 2.0)
            rec_buf = int(bdp_bytes * 3.0)
            max_buf = int(bdp_bytes * 4.0)

            print "Scenario: High-Throughput (Bulk Transfer)"
            printf "  Minimum: %d bytes (%d KB)\n", min_buf, int(min_buf/1024)
            printf "  Recommended: %d bytes (%d KB)\n", rec_buf, int(rec_buf/1024)
            printf "  Maximum: %d bytes (%d KB)\n", max_buf, int(max_buf/1024)
        }

        print ""
        print "4× MSS Check (minimum for fast recovery):"
        mss = 1460  # Standard Ethernet MSS
        min_4mss = mss * 4
        printf "  4 × MSS = %d bytes (%.2f KB)\n", min_4mss, min_4mss/1024

        if (rec_buf < min_4mss) {
            print "  ⚠ Recommended buffer is less than 4×MSS!"
            printf "  Suggest using minimum %d bytes for TCP fast recovery\n", min_4mss
        } else {
            print "  ✓ Recommended buffer meets 4×MSS requirement"
        }

        print ""
        print "setsockopt() values (kernel will double these):"
        printf "  SO_SNDBUF: %d\n", rec_buf
        printf "  SO_RCVBUF: %d\n", rec_buf
    }'
}

# Main
if [ $# -lt 3 ]; then
    echo "Usage: $0 <bandwidth_gbps> <rtt_ms> <scenario>"
    echo ""
    echo "Scenarios:"
    echo "  low-latency  - Message delivery, real-time apps (1.0-1.5× BDP)"
    echo "  balanced     - General purpose applications (1.5-2.5× BDP)"
    echo "  throughput   - Bulk transfers, backups (2.0-4.0× BDP)"
    echo ""
    echo "Example: $0 1 10 low-latency"
    exit 1
fi

calculate_buffer_size "$1" "$2" "$3"
```

## Practical Sizing for Different Traffic Profiles

### Scenario Analysis

Different application types have distinct characteristics that drive buffer sizing decisions:

```
┌─────────────────────────────────────────────────────────────────┐
│ TRAFFIC PROFILE CHARACTERISTICS                                 │
│                                                                 │
│ [1] Message Delivery Systems:                                   │
│   Message size: 1-5 KB per message                              │
│   Pattern: Request-response or streaming                        │
│   Requirements:                                                 │
│   ├─ Low latency (single-digit ms preferred)                    │
│   ├─ Minimal data loss during network disruption                │
│   ├─ High message frequency                                     │
│   └─ Small buffer footprint                                     │
│                                                                 │
│ [2] File Transfer Systems:                                      │
│   Transfer size: MB to GB per file                              │
│   Pattern: Bulk data streaming                                  │
│   Requirements:                                                 │
│   ├─ Maximum throughput                                         │
│   ├─ Efficient large buffer utilization                         │
│   ├─ Tolerance for moderate latency                             │
│   └─ Large buffer capacity                                      │
│                                                                 │
│ Network Topology:                                               │
│   Customer-facing (Internet): RTT 50-200ms (global)             │
│   Backend (Datacenter): RTT 0.5-5ms (same AZ/DC)                │
│   Regional: RTT 10-30ms (cross-region)                          │
└─────────────────────────────────────────────────────────────────┘
```

### Recommended Buffer Sizes

```bash
#!/bin/bash
# buffer-sizing-recommendations.sh

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v awk &> /dev/null || missing_deps+=("gawk")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

echo "===== Buffer Sizing Recommendations by Traffic Profile ====="
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MESSAGE DELIVERY PROFILE (Low Latency, 1-5KB messages)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Backend datacenter (1 Gbps, RTT 2ms)
echo "[1] Backend Datacenter (1 Gbps, RTT 2ms)"
awk 'BEGIN {
    BDP = 1000000000 * 0.002 / 8
    printf "  BDP: %d bytes (%d KB)\n", BDP, int(BDP/1024)
}'
echo "  Recommended SO_SNDBUF: 131072 (128 KB)"
echo "  Recommended SO_RCVBUF: 131072 (128 KB)"
echo "  Rationale: 1.5× BDP, minimal queuing delay"
echo ""

# Regional backend (1 Gbps, RTT 10ms)
echo "[2] Regional Backend (1 Gbps, RTT 10ms)"
awk 'BEGIN {
    BDP = 1000000000 * 0.010 / 8
    printf "  BDP: %d bytes (%d KB)\n", BDP, int(BDP/1024)
}'
echo "  Recommended SO_SNDBUF: 262144 (256 KB)"
echo "  Recommended SO_RCVBUF: 262144 (256 KB)"
echo "  Rationale: ~2× BDP for RTT variation tolerance"
echo ""

# Customer-facing (1 Gbps, RTT 100ms - Internet)
echo "[3] Customer-Facing Internet (1 Gbps, RTT 100ms)"
awk 'BEGIN {
    BDP = 1000000000 * 0.100 / 8
    printf "  BDP: %d bytes (%.2f MB)\n", BDP, BDP/1024/1024
}'
echo "  Recommended SO_SNDBUF: 2097152 (2 MB)"
echo "  Recommended SO_RCVBUF: 2097152 (2 MB)"
echo "  Rationale: ~1.5× BDP, handles jitter and packet loss"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FILE TRANSFER PROFILE (High Throughput)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# High-speed datacenter (10 Gbps, RTT 1ms)
echo "[4] High-Speed Datacenter (10 Gbps, RTT 1ms)"
awk 'BEGIN {
    BDP = 10000000000 * 0.001 / 8
    printf "  BDP: %d bytes (%d KB)\n", BDP, int(BDP/1024)
}'
echo "  Recommended SO_SNDBUF: 4194304 (4 MB)"
echo "  Recommended SO_RCVBUF: 4194304 (4 MB)"
echo "  Rationale: 3× BDP for maximum throughput"
echo ""

# Cross-region file transfer (10 Gbps, RTT 30ms)
echo "[5] Cross-Region Transfer (10 Gbps, RTT 30ms)"
awk 'BEGIN {
    BDP = 10000000000 * 0.030 / 8
    printf "  BDP: %d bytes (%.2f MB)\n", BDP, BDP/1024/1024
}'
echo "  Recommended SO_SNDBUF: 67108864 (64 MB)"
echo "  Recommended SO_RCVBUF: 67108864 (64 MB)"
echo "  Rationale: 2× BDP for sustained high-speed transfers"
echo ""

echo "General Guidelines:"
echo "  • Message delivery: Use 1.0-2.0× BDP for low latency"
echo "  • File transfer: Use 2.0-4.0× BDP for maximum throughput"
echo "  • Monitor actual usage with ss -tim"
echo "  • Adjust based on observed buffer utilization"
```

### Quick Reference Table

```
┌─────────────────────────────────────────────────────────────────┐
│ BUFFER SIZING QUICK REFERENCE                                   │
│                                                                 │
│ MESSAGE DELIVERY (1 Gbps baseline)                              │
│ ──────────────────────────────────────────────────────────────  │
│ Environment          RTT      BDP      Recommended Buffer       │
│                                                                 │
│ Same AZ/DC         0.5ms    62 KB     64-128 KB                 │
│ Local datacenter    2ms     250 KB     128-256 KB               │
│ Regional backend    10ms    1.2 MB     256-512 KB               │
│ Internet (global)  100ms   12.2 MB     2-4 MB                   │
│                                                                 │
│ FILE TRANSFER (10 Gbps baseline)                                │
│ ──────────────────────────────────────────────────────────────  │
│ Environment          RTT      BDP      Recommended Buffer       │
│                                                                 │
│ Same AZ/DC          1ms    1.2 MB     4-8 MB                    │
│ Regional            10ms   12.2 MB     16-32 MB                 │
│ Cross-region        30ms   37.5 MB     32-64 MB                 │
│ International      100ms   125 MB      64-128 MB                │
│                                                                 │
│ Notes:                                                          │
│ • Message delivery: Low latency focus (1.0-2.0× BDP)            │
│ • File transfer: Throughput focus (2.0-4.0× BDP)                │
│ • Scale BDP linearly with bandwidth changes                     │
│ • Monitor and adjust based on actual traffic patterns           │
└─────────────────────────────────────────────────────────────────┘
```

## Dynamic Buffer Adjustment

### Monitoring Buffer Utilization

```bash
#!/bin/bash
# monitor-buffer-usage.sh
# Track actual buffer utilization vs configured size

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v ss &> /dev/null || missing_deps+=("iproute")
    command -v awk &> /dev/null || missing_deps+=("gawk")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

INTERVAL=5

echo "Monitoring socket buffer utilization..."
echo "Press Ctrl+C to stop"
echo ""

while true; do
    echo "===== $(date) ====="
    
    # Analyze all established connections
    ss -tim state established | awk '
    /^ESTAB/ {
        # Extract destination
        split($5, dest, ":")
        dst = dest[1]
    }
    /skmem:/ {
        # Parse skmem values
        match($0, /r([0-9]+)/, r_queue)
        match($0, /rb([0-9]+)/, r_buf)
        match($0, /t([0-9]+)/, t_queue)
        match($0, /tb([0-9]+)/, t_buf)
        
        if (r_buf[1] > 0) {
            r_util = (r_queue[1] / r_buf[1]) * 100
            t_util = (t_queue[1] / t_buf[1]) * 100
            
            printf "%-20s RX: %3.0f%% (%d/%d) TX: %3.0f%% (%d/%d)\n",
                dst, r_util, r_queue[1], r_buf[1], t_util, t_queue[1], t_buf[1]
        }
    }
    ' | sort -k3 -rn | head -10
    
    echo ""
    sleep $INTERVAL
done
```

### Adaptive Buffer Tuning Script

```bash
#!/bin/bash
# adaptive-buffer-tuning.sh
# Suggest buffer adjustments based on actual usage patterns

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v ss &> /dev/null || missing_deps+=("iproute")
    command -v awk &> /dev/null || missing_deps+=("gawk")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

analyze_buffer_usage() {
    local interface="$1"
    local samples=60  # 5 minutes at 5-second intervals

    echo "Collecting buffer usage data for $samples samples..."
    
    # Temporary storage
    local tmp_file="/tmp/buffer-analysis-$$.txt"
    
    # Collect samples
    for i in $(seq 1 $samples); do
        ss -tim state established | awk '
        /skmem:/ {
            match($0, /rb([0-9]+)/, r_buf)
            match($0, /tb([0-9]+)/, t_buf)
            match($0, /r([0-9]+)/, r_queue)
            match($0, /t([0-9]+)/, t_queue)
            
            if (r_buf[1] > 0) {
                r_util = (r_queue[1] / r_buf[1]) * 100
                t_util = (t_queue[1] / t_buf[1]) * 100
                print r_util, t_util, r_buf[1], t_buf[1]
            }
        }
        ' >> "$tmp_file"
        sleep 5
    done
    
    # Analyze collected data
    awk '{
        r_sum += $1; r_sum_sq += $1*$1
        t_sum += $2; t_sum_sq += $2*$2
        if ($1 > r_max) r_max = $1
        if ($2 > t_max) t_max = $2
        n++
        
        # Track most common buffer sizes
        buf_r[$3]++
        buf_t[$4]++
    } END {
        if (n > 0) {
            r_avg = r_sum / n
            t_avg = t_sum / n
            r_stddev = sqrt(r_sum_sq/n - r_avg*r_avg)
            t_stddev = sqrt(t_sum_sq/n - t_avg*t_avg)
            
            print "===== Buffer Utilization Analysis ====="
            print ""
            print "Receive Buffer:"
            printf "  Average utilization: %.1f%%\n", r_avg
            printf "  Std deviation: %.1f%%\n", r_stddev
            printf "  Peak utilization: %.1f%%\n", r_max
            print ""
            print "Send Buffer:"
            printf "  Average utilization: %.1f%%\n", t_avg
            printf "  Std deviation: %.1f%%\n", t_stddev
            printf "  Peak utilization: %.1f%%\n", t_max
            print ""
            print "Recommendations:"
            
            # Receive buffer recommendations
            if (r_max > 90) {
                print "  ⚠ RX buffer frequently full (peak " r_max "%)"
                print "    → Increase SO_RCVBUF by 50-100%"
            } else if (r_avg < 20) {
                print "  ℹ RX buffer underutilized (avg " r_avg "%)"
                print "    → Can reduce SO_RCVBUF by 25-50%"
            } else {
                print "  ✓ RX buffer sizing appears optimal"
            }
            
            # Send buffer recommendations
            if (t_max > 90) {
                print "  ⚠ TX buffer frequently full (peak " t_max "%)"
                print "    → Increase SO_SNDBUF by 50-100%"
            } else if (t_avg < 20) {
                print "  ℹ TX buffer underutilized (avg " t_avg "%)"
                print "    → Can reduce SO_SNDBUF by 25-50%"
            } else {
                print "  ✓ TX buffer sizing appears optimal"
            }
        }
    }' "$tmp_file"
    
    rm -f "$tmp_file"
}

# Main
if [ $# -eq 0 ]; then
    echo "Usage: $0 <interface>"
    exit 1
fi

analyze_buffer_usage "$1"
```

## Validation and Testing

### Throughput Test Script

```bash
#!/bin/bash
# test-buffer-throughput.sh
# Test different buffer sizes to find optimal configuration

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v iperf3 &> /dev/null || missing_deps+=("iperf3")
    command -v grep &> /dev/null || missing_deps+=("grep")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

TARGET="$1"
PORT="${2:-5001}"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target_host> [port]"
    echo "Requires iperf3 server running on target"
    exit 1
fi

# Verify target is reachable
if ! ping -c 1 -W 2 "$TARGET" &> /dev/null; then
    echo "ERROR: Target host $TARGET is not reachable"
    exit 1
fi

# Test different buffer sizes
BUFFER_SIZES=(
    "32768"    # 32 KB
    "65536"    # 64 KB
    "131072"   # 128 KB
    "262144"   # 256 KB
    "524288"   # 512 KB
    "1048576"  # 1 MB
    "2097152"  # 2 MB
)

echo "===== Buffer Size Throughput Test ====="
echo "Target: $TARGET:$PORT"
echo ""

for size in "${BUFFER_SIZES[@]}"; do
    size_kb=$((size / 1024))
    echo -n "Testing ${size_kb}KB buffers... "
    
    # Run iperf3 with specific window size
    result=$(iperf3 -c "$TARGET" -p "$PORT" -t 10 -w "$size" -f m 2>/dev/null | \
        grep -oP 'receiver.*\K[0-9.]+(?= Mbits)')
    
    if [ ! -z "$result" ]; then
        echo "$result Mbits/sec"
    else
        echo "Failed"
    fi
done

echo ""
echo "Optimal buffer size: Use smallest size achieving maximum throughput"
```

### Latency vs Buffer Size Test

```bash
#!/bin/bash
# test-buffer-latency.sh
# Measure latency impact of different buffer sizes

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v ping &> /dev/null || missing_deps+=("iputils")
    command -v awk &> /dev/null || missing_deps+=("gawk")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies

TARGET="$1"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target_host>"
    exit 1
fi

# Verify target is reachable
if ! ping -c 1 -W 2 "$TARGET" &> /dev/null; then
    echo "ERROR: Target host $TARGET is not reachable"
    exit 1
fi

# Test different buffer sizes
BUFFER_SIZES=(
    "65536"    # 64 KB
    "131072"   # 128 KB
    "262144"   # 256 KB
    "524288"   # 512 KB
    "1048576"  # 1 MB
)

echo "===== Buffer Size Latency Test ====="
echo "Target: $TARGET"
echo ""
echo "Buffer Size | RTT (avg) | RTT (p99) | Jitter"
echo "------------|-----------|-----------|--------"

for size in "${BUFFER_SIZES[@]}"; do
    size_kb=$((size / 1024))
    
    # Measure RTT with different buffer sizes
    # This requires a test application that can set SO_SNDBUF/SO_RCVBUF
    # For simplicity, just measure baseline with ping
    result=$(ping -c 100 -q "$TARGET" 2>/dev/null | \
        grep rtt | awk '{print $4}' | tr '/' ' ')
    
    if [ ! -z "$result" ]; then
        read min avg max mdev <<< "$result"
        printf "%6d KB | %9s | %9s | %s\n" "$size_kb" "$avg ms" "$max ms" "$mdev ms"
    fi
done

echo ""
echo "Note: For accurate results, use application-level testing"
echo "with actual buffer size configuration"
```

## System-Wide Configuration

### Applying Calculated Buffer Sizes

```bash
#!/bin/bash
# apply-buffer-config.sh
# Apply calculated buffer sizes system-wide

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v awk &> /dev/null || missing_deps+=("gawk")
    command -v sysctl &> /dev/null || missing_deps+=("procps-ng")
    command -v tee &> /dev/null || missing_deps+=("coreutils")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required packages: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi

    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: This script must be run as root or with sudo"
        exit 1
    fi
}

check_dependencies

SNDBUF_SIZE="$1"
RCVBUF_SIZE="$2"

if [ -z "$SNDBUF_SIZE" ] || [ -z "$RCVBUF_SIZE" ]; then
    echo "Usage: $0 <sndbuf_size> <rcvbuf_size>"
    echo ""
    echo "Example: $0 262144 262144  # 256KB buffers"
    exit 1
fi

# Validate buffer sizes are numeric and reasonable
if ! [[ "$SNDBUF_SIZE" =~ ^[0-9]+$ ]] || ! [[ "$RCVBUF_SIZE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Buffer sizes must be numeric values"
    exit 1
fi

if [ "$SNDBUF_SIZE" -lt 4096 ] || [ "$RCVBUF_SIZE" -lt 4096 ]; then
    echo "ERROR: Buffer sizes must be at least 4096 bytes (4KB)"
    exit 1
fi

if [ "$SNDBUF_SIZE" -gt 134217728 ] || [ "$RCVBUF_SIZE" -gt 134217728 ]; then
    echo "WARNING: Buffer sizes > 128MB may cause memory pressure"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "===== Applying Buffer Configuration ====="
echo ""
# Use awk for calculations instead of bc
awk -v sndbuf="$SNDBUF_SIZE" -v rcvbuf="$RCVBUF_SIZE" 'BEGIN {
    printf "Send buffer size: %d bytes (%d KB)\n", sndbuf, int(sndbuf/1024)
    printf "Receive buffer size: %d bytes (%d KB)\n", rcvbuf, int(rcvbuf/1024)
}'
echo ""

# Calculate default buffer sizes (half of max)
RCVBUF_DEFAULT=$(awk -v val="$RCVBUF_SIZE" 'BEGIN {print int(val/2)}')
SNDBUF_DEFAULT=$(awk -v val="$SNDBUF_SIZE" 'BEGIN {print int(val/2)}')

# Create sysctl configuration
cat << EOF | sudo tee /etc/sysctl.d/99-buffer-sizing.conf
# Socket buffer sizing based on BDP calculations
# Applied: $(date)

# Maximum buffer sizes
net.core.rmem_max = $RCVBUF_SIZE
net.core.wmem_max = $SNDBUF_SIZE

# TCP auto-tuning (min, default, max)
# Min: 4KB (below this is problematic)
# Default: Half of max
# Max: Calculated value
net.ipv4.tcp_rmem = 4096 $RCVBUF_DEFAULT $RCVBUF_SIZE
net.ipv4.tcp_wmem = 4096 $SNDBUF_DEFAULT $SNDBUF_SIZE
EOF

# Apply settings
sudo sysctl -p /etc/sysctl.d/99-buffer-sizing.conf

echo ""
echo "Configuration applied successfully"
echo ""
echo "Verify with:"
echo "  sysctl net.core.rmem_max net.core.wmem_max"
echo "  sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem"
```

## Key Takeaways

1. **BDP Is the Foundation**: Bandwidth-Delay Product determines optimal buffer size
   - BDP = Bandwidth × RTT / 8
   - Buffer should be ≥ BDP for full throughput
   - But not excessively larger (causes bufferbloat)

2. **Measure, Don't Guess**: Accurate RTT measurement is critical
   - Use ping for baseline ICMP RTT
   - Use ss for actual TCP RTT
   - Application-level measurement is most accurate
   - Measure under load conditions

3. **Application Guidelines**: Match buffer size to traffic profile
   - Message delivery (backend): 128-512 KB for low latency
   - Message delivery (Internet): 2-4 MB for reliability over WAN
   - File transfer (datacenter): 4-32 MB for throughput
   - File transfer (cross-region): 32-128 MB for high-speed WAN
   - Always check 4× MSS minimum (5,840 bytes)

4. **Scenario-Based Sizing**: Different use cases need different approaches
   - Low-latency: 1.0-1.5× BDP
   - Balanced: 1.5-2.5× BDP
   - Throughput: 2.0-4.0× BDP
   - Never exceed 4× BDP

5. **Monitor and Adjust**: Buffer sizing is not set-and-forget
   - Monitor actual utilization with ss -tim
   - Look for consistently full buffers (need larger)
   - Look for low utilization (can reduce)
   - Adjust based on measured performance

6. **System-Wide vs Per-Socket**: Two configuration levels
   - System-wide: tcp_rmem/tcp_wmem (auto-tuning ranges)
   - Per-socket: SO_SNDBUF/SO_RCVBUF (application control)
   - System-wide is easier, per-socket is more precise

7. **Validation Is Essential**: Test before production deployment
   - Throughput tests with iperf3
   - Latency tests with ping and application-level tools
   - Compare different buffer sizes
   - Choose smallest size meeting performance requirements

## What's Next

With buffer sizing methodology established, the next documents cover complete system optimization:

- **[Low-Latency System Profile](08-low-latency-profile.md)**: Complete configuration checklist
- **[Diagnostics and Troubleshooting](09-diagnostics-and-troubleshooting.md)**: Identifying and fixing configuration issues
- **[Monitoring and Maintenance](10-monitoring-maintenance.md)**: Ongoing performance management

---

**Previous**: [Detecting Memory Pressure and Packet Loss Sources](06-detecting-issues.md)  
**Next**: [Ultra Low-Latency System Profile](08-low-latency-profile.md)
