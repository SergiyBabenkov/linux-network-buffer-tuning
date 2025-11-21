# Practical Shell Scripts and Recipes

## Overview

This document provides production-ready shell scripts and recipes for managing, monitoring, and troubleshooting network buffer configurations on RHEL/OEL 8 systems. Rather than repeating complete scripts from previous documents, this section focuses on practical command sequences, helper functions, and recipes for common operational tasks.

**Target Audience:** System administrators and operations engineers who need to implement and maintain network tuning in production environments.

## Buffer Configuration Diagnostics

### Recipe 1: Comprehensive Buffer Audit

This recipe checks all levels of the buffer hierarchy and identifies configuration problems.

```bash
#!/bin/bash
# Comprehensive buffer configuration audit
# Checks: core limits, TCP settings, window scaling, auto-tuning

echo "=== Comprehensive Buffer Audit ==="
echo ""

# Detect interface
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not determine default network interface"
    exit 1
fi

# Collect all settings
RMEM_MAX=$(sysctl -n net.core.rmem_max)
WMEM_MAX=$(sysctl -n net.core.wmem_max)
RMEM_DEFAULT=$(sysctl -n net.core.rmem_default)
WMEM_DEFAULT=$(sysctl -n net.core.wmem_default)

TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)
TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem)
read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"

WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)
AUTO_TUNING=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)
TCP_MEM=$(sysctl -n net.ipv4.tcp_mem)
read TCP_MEM_LOW TCP_MEM_PRESS TCP_MEM_HIGH <<< "$TCP_MEM"

# Display core settings
echo "[Core Buffer Limits]"
echo "  rmem_max:           $RMEM_MAX bytes ($(($RMEM_MAX / 1048576))MB)"
echo "  wmem_max:           $WMEM_MAX bytes ($(($WMEM_MAX / 1048576))MB)"
echo "  rmem_default:       $RMEM_DEFAULT bytes"
echo "  wmem_default:       $WMEM_DEFAULT bytes"
echo ""

# Display TCP settings
echo "[TCP Auto-Tuning Configuration]"
echo "  tcp_rmem[0]:        $TCP_RMEM_MIN (min allocation)"
echo "  tcp_rmem[1]:        $TCP_RMEM_DEF (default)"
echo "  tcp_rmem[2]:        $TCP_RMEM_MAX (max auto-tune)"
echo "  tcp_wmem[0]:        $TCP_WMEM_MIN (min allocation)"
echo "  tcp_wmem[1]:        $TCP_WMEM_DEF (default)"
echo "  tcp_wmem[2]:        $TCP_WMEM_MAX (max auto-tune)"
echo "  window_scaling:     $WINDOW_SCALING"
echo "  auto_tuning:        $AUTO_TUNING"
echo ""

# Display memory limits
echo "[TCP Memory Limits (in 4KB pages)]"
echo "  tcp_mem low:        $TCP_MEM_LOW (approx $(($TCP_MEM_LOW * 4 / 1024))MB)"
echo "  tcp_mem pressure:   $TCP_MEM_PRESS (approx $(($TCP_MEM_PRESS * 4 / 1024))MB)"
echo "  tcp_mem high:       $TCP_MEM_HIGH (approx $(($TCP_MEM_HIGH * 4 / 1024))MB)"
echo ""

# Validation checks
echo "[Validation Checks]"
ERRORS=0

# Check 1: tcp_rmem[2] <= rmem_max
if (( TCP_RMEM_MAX > RMEM_MAX )); then
    echo "  L tcp_rmem[2] ($TCP_RMEM_MAX) exceeds rmem_max ($RMEM_MAX)"
    echo "     � Auto-tuning will be limited"
    ((ERRORS++))
else
    echo "   tcp_rmem[2] <= rmem_max"
fi

# Check 2: tcp_wmem[2] <= wmem_max
if (( TCP_WMEM_MAX > WMEM_MAX )); then
    echo "  L tcp_wmem[2] ($TCP_WMEM_MAX) exceeds wmem_max ($WMEM_MAX)"
    ((ERRORS++))
else
    echo "   tcp_wmem[2] <= wmem_max"
fi

# Check 3: Window scaling required for large buffers
if (( TCP_RMEM_MAX > 65536 )) && [[ $WINDOW_SCALING -ne 1 ]]; then
    echo "  L Window scaling disabled but tcp_rmem[2] > 64KB"
    echo "     � Large windows won't be used"
    ((ERRORS++))
else
    echo "   Window scaling configuration correct"
fi

# Check 4: Auto-tuning enabled
if [[ $AUTO_TUNING -ne 1 ]]; then
    echo "  �  Auto-tuning disabled (tcp_moderate_rcvbuf = 0)"
    echo "     � Applications must set buffers manually"
else
    echo "   Auto-tuning enabled"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo " All checks passed"
else
    echo "L Found $ERRORS configuration errors"
fi
```

### Recipe 2: Current Memory Usage Analysis

Check how much TCP memory is currently in use and how close to limits.

```bash
#!/bin/bash
# Analyze current TCP memory usage relative to limits

echo "=== TCP Memory Usage Analysis ==="
echo ""

# Get limits
TCP_MEM_LIMITS=$(sysctl -n net.ipv4.tcp_mem)
read LOW PRESS HIGH <<< "$TCP_MEM_LIMITS"

# Get current usage (in pages, 4KB each)
CURRENT=$(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $11}')

# Convert to MB for readability
LOW_MB=$(($LOW * 4 / 1024))
PRESS_MB=$(($PRESS * 4 / 1024))
HIGH_MB=$(($HIGH * 4 / 1024))
CURRENT_MB=$(($CURRENT * 4 / 1024))

# Calculate percentages
LOW_PCT=$((CURRENT * 100 / LOW))
PRESS_PCT=$((CURRENT * 100 / PRESS))
HIGH_PCT=$((CURRENT * 100 / HIGH))

echo "TCP Memory Status:"
echo "  Current usage:    $CURRENT pages ($CURRENT_MB MB)"
echo ""

echo "Relative to thresholds:"
echo "  Low threshold:    $LOW pages ($LOW_MB MB) - Current: $LOW_PCT%"
echo "  Pressure:         $PRESS pages ($PRESS_MB MB) - Current: $PRESS_PCT%"
echo "  High (limit):     $HIGH pages ($HIGH_MB MB) - Current: $HIGH_PCT%"
echo ""

# Warning logic
if (( CURRENT > HIGH )); then
    echo "�  CRITICAL: Memory usage above hard limit!"
    echo "   TCP will start rejecting new connections"
elif (( CURRENT > PRESS )); then
    echo "�  WARNING: Memory pressure threshold exceeded"
    echo "   TCP may start reducing buffer allocations"
elif (( CURRENT > LOW )); then
    echo "9  INFO: Memory usage above low threshold"
    echo "   Normal operation, approaching pressure zone"
else
    echo " Memory usage healthy"
fi

echo ""
echo "Active connections: $(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $3}') (inuse)"
echo "Orphaned sockets:   $(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $5}') (orphan)"
```

### Recipe 3: Per-Connection Buffer Inspection

View actual socket buffer sizes for specific connections.

```bash
#!/bin/bash
# Show actual socket buffer usage for connections
# Usage: ./script.sh [optional: destination_ip]

DST_IP="${1:-}"

if [ -z "$DST_IP" ]; then
    echo "Usage: $0 <destination_ip>"
    echo ""
    echo "Shows actual socket buffer allocations for connections to destination"
    exit 1
fi

echo "=== Socket Buffers for Connections to $DST_IP ==="
echo ""

# Use ss to show memory info
# Format: skmem:(r<recv>,rb<rcvbuf>,t<send>,tb<sndbuf>)
ss -tm dst $DST_IP | grep -E "State|skmem" | awk '
BEGIN {
    print "Format: r=recv_bytes, rb=recv_limit, t=send_bytes, tb=send_limit"
    print ""
    print "Connections:"
}
/State/ {
    getline
    print "  " $0
}'

echo ""
echo "Interpretation:"
echo "  r  = bytes currently in receive queue"
echo "  rb = receive buffer limit (SO_RCVBUF)"
echo "  t  = bytes currently in send queue"
echo "  tb = send buffer limit (SO_SNDBUF)"
```

## Network Interface Diagnostics

### Recipe 4: Interface Configuration Status

Quick check of critical interface settings for latency optimization.

```bash
#!/bin/bash
# Check network interface configuration for low-latency optimization

# Detect interface
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not determine default network interface"
    exit 1
fi

echo "=== Network Interface Configuration: $INTERFACE ==="
echo ""

# Layer 1: Physical/Link
echo "[Layer 1: Physical/Link Layer]"
ip link show $INTERFACE | head -2
ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*RX:"
ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*TX:"
echo ""

# Layer 2: MTU and Qdisc
echo "[Layer 2: MTU and Queue Discipline]"
MTU=$(ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+')
QLEN=$(ip link show $INTERFACE | grep -oP 'qlen \K[0-9]+')
echo "  MTU:                $MTU"
echo "  TX Queue Length:    $QLEN"

QDISC=$(tc qdisc show dev $INTERFACE | head -1)
echo "  Qdisc:              $QDISC"
echo ""

# Layer 3: Ring buffers (NIC)
echo "[Layer 3: NIC Ring Buffers]"
if ethtool -g $INTERFACE &>/dev/null 2>&1; then
    ethtool -g $INTERFACE | grep -E "^(RX|TX)"
else
    echo "  Ring buffer info not available (check ethtool permissions)"
fi
echo ""

# Layer 4: Interrupt settings
echo "[Layer 4: Interrupt Handling]"
IRQ=$(grep $INTERFACE /proc/interrupts 2>/dev/null | awk '{print $1}' | sed 's/:$//' | head -1)
if [ ! -z "$IRQ" ]; then
    COALESCE_RX=$(ethtool -c $INTERFACE 2>/dev/null | grep "rx-usecs:" | awk '{print $2}')
    COALESCE_TX=$(ethtool -c $INTERFACE 2>/dev/null | grep "tx-usecs:" | awk '{print $2}')
    echo "  IRQ:                $IRQ"
    echo "  RX Coalesce (usecs): $COALESCE_RX"
    echo "  TX Coalesce (usecs): $COALESCE_TX"

    if [ "$COALESCE_RX" = "0" ] && [ "$COALESCE_TX" = "0" ]; then
        echo "  Status:              Coalescing disabled (low latency)"
    else
        echo "  Status:             �  Coalescing enabled (may increase latency)"
    fi
else
    echo "  Could not determine interface IRQ"
fi
echo ""

# Drops and errors
echo "[Errors and Drops]"
RX_DROP=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*RX:" | grep "dropped" | awk '{print $1}')
TX_DROP=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*TX:" | grep "dropped" | awk '{print $1}')
RX_ERR=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*RX:" | grep "errors" | awk '{print $1}')
TX_ERR=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*TX:" | grep "errors" | awk '{print $1}')

echo "  RX drops:           $RX_DROP"
echo "  TX drops:           $TX_DROP"
echo "  RX errors:          $RX_ERR"
echo "  TX errors:          $TX_ERR"

if [ "$RX_DROP" -gt 0 ] || [ "$TX_DROP" -gt 0 ]; then
    echo "  �  Packet drops detected - check buffer sizing"
fi
```

## Performance Monitoring Recipes

### Recipe 5: Real-Time Latency and Drops Monitoring

Monitor packet drops and latency indicators in real-time.

```bash
#!/bin/bash
# Real-time monitoring of drops and latency indicators
# Updates every 2 seconds

# Detect interface
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not determine default network interface"
    exit 1
fi

INTERVAL=${1:-2}

echo "=== Real-Time Network Monitoring ($INTERVAL second intervals) ==="
echo "Press Ctrl+C to stop"
echo ""

# Function to get stats
get_stats() {
    # Get interface stats
    RX=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*RX:" | head -2 | tail -1 | awk '{print $1}')
    RX_DROP=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*RX:" | head -2 | tail -1 | awk '{print $4}')
    TX=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*TX:" | head -2 | tail -1 | awk '{print $1}')
    TX_DROP=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*TX:" | head -2 | tail -1 | awk '{print $4}')

    # Get TCP stats
    TCP_RETRANS=$(netstat -s 2>/dev/null | grep "segments retransmitted" | awk '{print $1}')

    echo "[$INTERFACE] $(date '+%H:%M:%S')"
    echo "  RX: $RX packets, $RX_DROP dropped"
    echo "  TX: $TX packets, $TX_DROP dropped"
    echo "  TCP retransmissions: $TCP_RETRANS"

    if [ "$RX_DROP" -gt 0 ] || [ "$TX_DROP" -gt 0 ]; then
        echo "  �  Packet loss detected"
    fi
    echo ""
}

# Main loop
while true; do
    clear
    echo "=== Real-Time Network Monitoring ($INTERFACE) ==="
    echo "Updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    get_stats

    echo "Qdisc Status:"
    tc -s qdisc show dev $INTERFACE | head -4
    echo ""

    sleep $INTERVAL
done
```

### Recipe 6: Bandwidth and RTT Measurement

Measure actual bandwidth utilization and RTT for active connections.

```bash
#!/bin/bash
# Measure RTT and available bandwidth for connections

# Detect interface
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not determine default network interface"
    exit 1
fi

TARGET_IP="${1:-}"
if [ -z "$TARGET_IP" ]; then
    echo "Usage: $0 <target_ip>"
    echo ""
    echo "Measures RTT and estimates bandwidth for connections to target"
    exit 1
fi

echo "=== Network Performance Measurement: $TARGET_IP ==="
echo ""

# RTT measurement using ping (100 packets, TCP-like size)
echo "[Round Trip Time (RTT)]"
ping -c 100 -s 1460 $TARGET_IP 2>/dev/null | tail -2

echo ""
echo "[TCP Connection RTT from ss]"
ss -ti dst $TARGET_IP 2>/dev/null | grep "rtt:" | head -5

echo ""
echo "[Connection Details]"
ss -tn dst $TARGET_IP 2>/dev/null | tail -5

echo ""
echo "Interpretation:"
echo "  - RTT affects buffer sizing (see document 07)"
echo "  - Higher jitter indicates unstable connection"
echo "  - For 1-2KB messages:"
echo "    " Datacenter (1-5ms RTT): 64-128KB buffers"
echo "    " Internet (50-200ms RTT): 256-512KB buffers"
```

## Tuning Helper Functions

### Recipe 7: Batch Apply Kernel Parameters

Safely apply network parameter changes with validation.

```bash
#!/bin/bash
# Apply kernel parameters with rollback capability

apply_kernel_params() {
    local PROFILE="${1:-message-delivery-backend}"

    # Backup current config
    BACKUP_FILE="/root/sysctl-backup-$(date +%s).conf"
    echo "Backing up current config to $BACKUP_FILE"
    sysctl -a > "$BACKUP_FILE"

    case "$PROFILE" in
        message-delivery-backend)
            # Small buffers for datacenter (1-5ms RTT)
            echo "Applying message-delivery-backend profile"
            sysctl -w net.ipv4.tcp_rmem="4096 32768 131072"
            sysctl -w net.ipv4.tcp_wmem="4096 32768 131072"
            sysctl -w net.core.rmem_max="131072"
            sysctl -w net.core.wmem_max="131072"
            ;;
        message-delivery-internet)
            # Medium buffers for Internet (50-200ms RTT)
            echo "Applying message-delivery-internet profile"
            sysctl -w net.ipv4.tcp_rmem="4096 262144 4194304"
            sysctl -w net.ipv4.tcp_wmem="4096 262144 4194304"
            sysctl -w net.core.rmem_max="4194304"
            sysctl -w net.core.wmem_max="4194304"
            ;;
        *)
            echo "Unknown profile: $PROFILE"
            return 1
            ;;
    esac

    # Common settings for both
    sysctl -w net.ipv4.tcp_window_scaling=1
    sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
    sysctl -w net.ipv4.tcp_congestion_control=bbr

    echo "Parameters applied. Backup: $BACKUP_FILE"
    return 0
}

rollback_kernel_params() {
    local BACKUP_FILE="$1"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "Backup file not found: $BACKUP_FILE"
        return 1
    fi

    echo "Rolling back to $BACKUP_FILE"
    sysctl -p "$BACKUP_FILE" > /dev/null
    echo "Rollback complete"
    return 0
}

# Usage in scripts:
# apply_kernel_params message-delivery-internet
# rollback_kernel_params /root/sysctl-backup-1234567890.conf
```

### Recipe 8: Interface Configuration Helper

Safely configure network interface with validation.

```bash
#!/bin/bash
# Configure network interface with error checking

configure_interface_for_latency() {
    local INTERFACE="${1:-}"

    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
        if [ -z "$INTERFACE" ]; then
            echo "Error: Could not determine interface"
            return 1
        fi
    fi

    echo "Configuring $INTERFACE for low-latency operation"

    # MTU (standard 1500 for compatibility)
    echo "  Setting MTU to 1500"
    ip link set $INTERFACE mtu 1500 || return 1

    # TX queue (reduce buffering)
    echo "  Setting TX queue length to 500"
    ip link set $INTERFACE txqueuelen 500 || return 1

    # Ring buffers (reduce hardware buffering)
    echo "  Setting NIC ring buffers (rx:256 tx:256)"
    ethtool -G $INTERFACE rx 256 tx 256 2>/dev/null || \
        echo "    (Ring buffer adjustment not supported)"

    # Interrupt coalescing (disable for immediate processing)
    echo "  Disabling interrupt coalescing"
    ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null || \
        echo "    (Interrupt coalescing control not available)"

    # Qdisc (fair queue with pacing)
    echo "  Setting qdisc to fq (fair queue)"
    tc qdisc replace dev $INTERFACE root fq pacing || return 1

    echo " Interface configuration complete"
    return 0
}

# Usage:
# configure_interface_for_latency eth0
# configure_interface_for_latency  # auto-detect
```

## Troubleshooting Recipes

### Recipe 9: Identify Packet Loss Source

Systematically determine where packets are being dropped.

```bash
#!/bin/bash
# Identify where packet loss is occurring

# Detect interface
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not determine default network interface"
    exit 1
fi

echo "=== Packet Loss Source Identification ==="
echo "Interface: $INTERFACE"
echo ""

echo "[Layer 1: Physical Interface Drops]"
RX_DROP=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*RX:" | head -2 | tail -1 | awk '{print $4}')
TX_DROP=$(ip -s link show $INTERFACE | grep -A 4 "^[[:space:]]*TX:" | head -2 | tail -1 | awk '{print $4}')
echo "  RX drops: $RX_DROP"
echo "  TX drops: $TX_DROP"

if [ "$RX_DROP" -gt 0 ] || [ "$TX_DROP" -gt 0 ]; then
    echo "  � Check: Ring buffer sizes, interrupt coalescing"
fi
echo ""

echo "[Layer 2: Qdisc Queue Drops]"
QDISC_DROP=$(tc -s qdisc show dev $INTERFACE | grep dropped | awk '{print $1}')
if [ ! -z "$QDISC_DROP" ]; then
    echo "  Drops: $QDISC_DROP"
    if [ "$QDISC_DROP" -gt 0 ]; then
        echo "  � Check: TX queue length, qdisc configuration"
    fi
else
    echo "  No drops detected at qdisc level"
fi
echo ""

echo "[Layer 3: Socket Buffer Overflows]"
SOCK_DROP=$(netstat -s 2>/dev/null | grep -i "segments.received.out.of.order" | awk '{print $1}')
if [ ! -z "$SOCK_DROP" ] && [ "$SOCK_DROP" -gt 0 ]; then
    echo "  Out-of-order segments: $SOCK_DROP"
    echo "  � Check: Socket buffer sizes, RTT variability"
fi
echo ""

echo "[Layer 4: TCP Retransmissions]"
RETRANS=$(netstat -s 2>/dev/null | grep "segments retransmitted" | awk '{print $1}')
echo "  Retransmissions: $RETRANS"

if [ "$RETRANS" -gt 100 ]; then
    echo "  � Check: Network stability, congestion control, packet loss"
fi
echo ""

echo "[Memory Pressure Drops]"
TCP_MEM=$(sysctl -n net.ipv4.tcp_mem)
read LOW PRESS HIGH <<< "$TCP_MEM"
CURRENT=$(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $11}')

PCT=$((CURRENT * 100 / HIGH))
echo "  TCP memory: $CURRENT pages / $HIGH pages threshold ($PCT%)"

if (( CURRENT > PRESS )); then
    echo "  � WARNING: Approaching memory limit, drops may occur"
fi
```

## Quick Command Reference

### Common One-Liners

```bash
# View all critical buffer settings
sysctl net.core.{rmem,wmem}_max net.ipv4.tcp_{rmem,wmem} net.ipv4.tcp_mem

# Check interface statistics
ip -s link show $(ip route show default | awk '/default/ {print $5; exit}')

# View active connections and their buffers
ss -tn | awk 'NR>1 {print $4}' | cut -d: -f1 | sort -u | while read ip; do
    echo "=== $ip ==="
    ss -tm dst $ip
done

# Monitor drops in real-time
watch -n 1 'ip -s link show $(ip route show default | awk "/default/ {print $5; exit}") | grep -E "RX|TX"'

# Check for memory pressure
awk '{print "Low:", $1, "Pressure:", $2, "High:", $3}' /proc/sys/net/ipv4/tcp_mem

# View qdisc details
tc -s qdisc show dev $(ip route show default | awk '/default/ {print $5; exit}')

# Get active TCP connections count
ss -tn | wc -l

# Check if window scaling is enabled
sysctl net.ipv4.tcp_window_scaling

# Measure RTT to target
ping -c 10 -s 1460 <target_ip> | tail -1
```

## Implementation Workflow

### Step 1: Baseline Assessment

```bash
# Run comprehensive audit
./recipe-1-comprehensive-audit.sh

# Check memory usage
./recipe-2-memory-analysis.sh

# Inspect interface
./recipe-4-interface-status.sh
```

### Step 2: Identify Issues

```bash
# Troubleshoot packet loss
./recipe-9-packet-loss-source.sh

# Monitor in real-time
./recipe-5-realtime-monitoring.sh
```

### Step 3: Apply Configuration

```bash
# Apply appropriate profile
./recipe-7-batch-apply-params.sh message-delivery-internet

# Configure interface
./recipe-8-interface-config.sh

# Validate changes
./recipe-1-comprehensive-audit.sh
```

### Step 4: Monitor Effectiveness

```bash
# Run ongoing monitoring
./recipe-5-realtime-monitoring.sh

# Periodic validation
./recipe-6-performance-measurement.sh <target_ip>
```

## What's Next

This document completes the practical implementation guides (07-11). The recipes provided here serve as templates and references for operational tasks.

**For continuous improvement:**
- Review drops and errors regularly using Recipe 5
- Adjust buffer sizes based on actual RTT measurements (Recipe 6)
- Monitor memory pressure and adjust limits accordingly (Recipe 2)
- Keep baseline measurements from Recipe 1 for comparison

**Key Files Referenced:**
- **CLAUDE.md** - Project guidelines including network interface detection pattern
- **08-low-latency-profile.md** - System configuration procedures
- **07-rtt-buffer-sizing.md** - Buffer calculation methodology
- **scripts/** - Production deployment scripts (network_buffer_audit.sh, etc.)

---

**Previous**: [Low-Latency System Profile](08-low-latency-profile.md)

**Project Documentation** (01-11): Complete understanding of Linux network buffer optimization from data journey through production deployment.
