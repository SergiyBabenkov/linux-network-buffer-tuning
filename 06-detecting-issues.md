# Detecting Memory Pressure and Packet Loss Sources

## Overview

Identifying the source of network problems is often more challenging than fixing them. Memory pressure, packet loss, and buffer overflows can occur at multiple points in the network stack, and each requires different diagnostic approaches and solutions.

This document provides systematic methods for detecting and diagnosing network issues in production systems, with emphasis on tools available on RHEL/OEL 8, interpretation of kernel statistics, and root cause analysis techniques.

## Diagnostic Strategy

### The Layered Approach

Network problems manifest at different layers. Start from the application and work down through the stack:

```
┌─────────────────────────────────────────────────────────────────┐
│ DIAGNOSTIC LAYER MODEL                                          │
│                                                                 │
│ Layer 7: Application                                            │
│   Symptoms: Slow responses, timeouts, errors                    │
│   Tools: Application logs, strace, ltrace                       │
│   ↓                                                             │
│ Layer 6: Socket Buffers                                         │
│   Symptoms: Blocked writes, full buffers                        │
│   Tools: ss, netstat, /proc/net/sockstat                        │
│   ↓                                                             │
│ Layer 5: TCP/IP Stack                                           │
│   Symptoms: Retransmissions, out-of-order packets               │
│   Tools: netstat -s, nstat, /proc/net/snmp                      │
│   ↓                                                             │
│ Layer 4: Queueing Discipline                                    │
│   Symptoms: Queue drops, backlog                                │
│   Tools: tc -s, ip -s link                                      │
│   ↓                                                             │
│ Layer 3: Network Interface                                      │
│   Symptoms: RX/TX errors, drops                                 │
│   Tools: ethtool -S, ifconfig, ip -s link                       │
│   ↓                                                             │
│ Layer 2: Physical/Driver                                        │
│   Symptoms: CRC errors, collisions, driver errors               │
│   Tools: dmesg, ethtool, driver logs                            │
└─────────────────────────────────────────────────────────────────┘
```

### Quick Diagnostic Checklist

Before deep diving, run this quick check:

```bash
#!/bin/bash
# quick-network-check.sh
# Fast network health assessment

echo "===== Quick Network Diagnostic Check ====="
echo ""

# 1. Check for TCP memory pressure
echo "[1] TCP Memory Pressure:"
cat /proc/net/sockstat | grep TCP
TCP_MEM=$(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $11}')
TCP_HIGH=$(cat /proc/sys/net/ipv4/tcp_mem | awk '{print $3}')
PCT=$(echo "scale=1; $TCP_MEM * 100 / $TCP_HIGH" | bc)
echo "    Memory usage: $PCT% of high threshold"

# 2. Check for packet drops at interface
echo ""
echo "[2] Interface Drops:"
ip -s link show | grep -A 4 "^[0-9]" | grep -E "eth|drops"

# 3. Check for TCP retransmissions
echo ""
echo "[3] TCP Retransmissions:"
netstat -s | grep -i retrans | head -3

# 4. Check for socket buffer overflows
echo ""
echo "[4] Socket Buffer Stats:"
netstat -s | grep -i "buffer"

# 5. Check qdisc drops
echo ""
echo "[5] Qdisc Queue Drops:"
tc -s qdisc show | grep -A 2 "qdisc"

echo ""
echo "===== End Quick Check ====="
```

## Detecting Memory Pressure

### TCP Memory Pressure Indicators

#### Method 1: /proc/net/sockstat

```bash
# Check current TCP memory usage
cat /proc/net/sockstat

# Output example:
# sockets: used 850
# TCP: inuse 180 orphan 5 tw 45 alloc 200 mem 2800
#                                              ^^^^
#                                    Memory in pages (4KB)

# Compare against limits
cat /proc/sys/net/ipv4/tcp_mem
# 188888 251851 377776
# Low    Press  High

# Calculate percentage
TCP_MEM=$(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $11}')
read LOW PRESS HIGH <<< $(cat /proc/sys/net/ipv4/tcp_mem)

echo "Current: $TCP_MEM pages"
echo "Low threshold: $LOW pages ($(echo "scale=1; $TCP_MEM * 100 / $LOW" | bc)%)"
echo "Pressure threshold: $PRESS pages ($(echo "scale=1; $TCP_MEM * 100 / $PRESS" | bc)%)"
echo "High threshold: $HIGH pages ($(echo "scale=1; $TCP_MEM * 100 / $HIGH" | bc)%)"
```

#### Method 2: /proc/net/protocols

```bash
# Check if TCP is under memory pressure
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

#### Method 3: Kernel Messages

```bash
# Check for memory pressure warnings in kernel logs
dmesg | grep -i "tcp.*memory"

# Common messages:
# TCP: out of memory
# TCP: memory pressure (mem=250000)
# TCP: too many orphaned sockets

# Also check system log
grep -i "tcp.*memory" /var/log/messages

# For real-time monitoring
dmesg -w | grep -i tcp
```

#### Method 4: Per-Socket Memory Usage

```bash
# Check memory usage for individual sockets
ss -tim

# Output includes:
# skmem:(r0,rb131072,t0,tb87040,f0,w0,o0,bl0,d0)
#        ^^       ^^       ^^
#        |        |        |
# r = receive queue bytes
# rb = receive buffer size
# t = transmit queue bytes  
# tb = transmit buffer size

# Script to find sockets using most memory
ss -tim | awk '/skmem:/ {
    match($0, /rb([0-9]+)/, rb)
    match($0, /tb([0-9]+)/, tb)
    total = (rb[1] + tb[1]) / 1024 / 1024
    if (total > 0) print total " MB - " $0
}' | sort -rn | head -10
```

### Memory Pressure Response Script

```bash
#!/bin/bash
# detect-memory-pressure.sh
# Comprehensive memory pressure detection and alerting

ALERT_THRESHOLD=80  # Alert at 80% of pressure threshold
CRITICAL_THRESHOLD=95  # Critical at 95% of high threshold

while true; do
    # Get current values
    TCP_MEM=$(cat /proc/net/sockstat | grep "^TCP:" | awk '{print $11}')
    read LOW PRESS HIGH <<< $(cat /proc/sys/net/ipv4/tcp_mem)
    
    # Calculate percentages
    PCT_PRESS=$(echo "scale=1; $TCP_MEM * 100 / $PRESS" | bc)
    PCT_HIGH=$(echo "scale=1; $TCP_MEM * 100 / $HIGH" | bc)
    
    # Determine status
    if (( $(echo "$PCT_HIGH > $CRITICAL_THRESHOLD" | bc -l) )); then
        STATUS="CRITICAL"
        COLOR="\033[31m"  # Red
        
        # Log critical event
        echo "$(date): CRITICAL - TCP memory at ${PCT_HIGH}% of high threshold" >> /var/log/tcp-memory.log
        
        # Get top memory consumers
        echo "Top socket memory consumers:" >> /var/log/tcp-memory.log
        ss -tim | awk '/skmem:/ {
            match($0, /rb([0-9]+)/, rb)
            match($0, /tb([0-9]+)/, tb)
            total = (rb[1] + tb[1]) / 1024 / 1024
            if (total > 1) print total " MB - " $0
        }' | sort -rn | head -5 >> /var/log/tcp-memory.log
        
    elif (( $(echo "$PCT_PRESS > $ALERT_THRESHOLD" | bc -l) )); then
        STATUS="WARNING"
        COLOR="\033[33m"  # Yellow
        
    else
        STATUS="NORMAL"
        COLOR="\033[32m"  # Green
    fi
    
    # Display
    clear
    echo -e "${COLOR}===== TCP Memory Pressure Monitor =====${NC}"
    echo ""
    echo -e "Status: ${COLOR}${STATUS}\033[0m"
    echo ""
    echo "Current usage: $TCP_MEM pages ($(echo "scale=2; $TCP_MEM * 4 / 1024" | bc) MB)"
    echo "  % of pressure threshold: $PCT_PRESS%"
    echo "  % of high threshold: $PCT_HIGH%"
    echo ""
    echo "Thresholds:"
    echo "  Low:      $LOW pages ($(echo "scale=2; $LOW * 4 / 1024" | bc) MB)"
    echo "  Pressure: $PRESS pages ($(echo "scale=2; $PRESS * 4 / 1024" | bc) MB)"
    echo "  High:     $HIGH pages ($(echo "scale=2; $HIGH * 4 / 1024" | bc) MB)"
    echo ""
    echo "TCP connections: $(ss -s | grep TCP: | awk '{print $2}')"
    echo "Orphaned sockets: $(cat /proc/net/sockstat | grep TCP | awk '{print $5}')"
    echo ""
    echo "Press Ctrl+C to exit"
    
    sleep 5
done
```

## Detecting Packet Loss

### Layer 3: TCP/IP Stack Statistics

#### Using netstat -s

```bash
# Comprehensive TCP/IP statistics
netstat -s

# Key sections to monitor:

# 1. TCP Retransmissions (indicates packet loss or corruption)
netstat -s | grep -i retrans
# Output:
#     12345 segments retransmitted
#     678 retransmits in slow start
#     90 fast retransmits

# 2. TCP Failures
netstat -s | grep -i fail
# Output:
#     45 failed connection attempts
#     23 connection resets received

# 3. Receive errors
netstat -s | grep -i "receive.*error"

# 4. Send errors  
netstat -s | grep -i "send.*error"

# 5. Buffer issues
netstat -s | grep -i buffer
# Output:
#     156 times the listen queue of a socket overflowed
#     234 SYNs to LISTEN sockets dropped

# 6. Out of order packets
netstat -s | grep -i "out of order"
# Output:
#     890 packets received out of order
```

#### Using nstat (delta statistics)

```bash
# Show rate of change (better for monitoring)
nstat -az

# Output shows only non-zero counters with deltas
# TcpRetransSegs                  12        0.0
# TcpExtTCPLostRetransmit         3         0.0
# TcpExtTCPFastRetrans            5         0.0

# Monitor continuously (5 second intervals)
watch -n 5 'nstat | grep -i retrans'

# Focused monitoring script
#!/bin/bash
# monitor-tcp-stats.sh
while true; do
    clear
    echo "===== TCP Statistics (5-second deltas) ====="
    echo ""
    nstat -az | grep -E "(Retrans|Loss|Reset|Fail|Drop)" | head -20
    sleep 5
done
```

#### Reading /proc/net/snmp

```bash
# Raw TCP statistics
cat /proc/net/snmp | grep -A 1 "^Tcp:"

# Output format:
# Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens ...
# Tcp: 1 200 120000 -1 12345 6789 ...

# Parse retransmission counter
awk '/^Tcp:/ && NR==2 {print "Retransmitted segments: " $13}' /proc/net/snmp

# Monitor specific counters over time
watch -n 1 'awk "/^Tcp:/ && NR==2 {
    print \"Active Opens: \" \$6
    print \"Passive Opens: \" \$7  
    print \"Failed Attempts: \" \$8
    print \"Resets Sent: \" \$15
    print \"Segs Out: \" \$12
    print \"Segs Retrans: \" \$13
}" /proc/net/snmp'
```

### Layer 4: Queueing Discipline Drops

```bash
# Check qdisc statistics
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tc -s qdisc show dev $DEFAULT_IF

# Output example:
# qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514
#  Sent 123456789 bytes 98765 pkt (dropped 45, overlimits 123 requeues 0)
#       ^^^^^^^^^^^^^^^^^^^^^^^^        ^^         ^^^
#       Total traffic                   Drops      Over limit events

# Parse drops
tc -s qdisc show dev $DEFAULT_IF | grep "dropped" | awk '{print "Dropped packets: " $8}'

# Monitor qdisc drops in real-time
#!/bin/bash
# monitor-qdisc-drops.sh
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
PREV_DROPS=0

while true; do
    CURRENT=$(tc -s qdisc show dev $INTERFACE | grep dropped | awk '{print $8}')
    
    if [ ! -z "$CURRENT" ]; then
        DELTA=$((CURRENT - PREV_DROPS))
        
        if [ $DELTA -gt 0 ]; then
            echo "$(date): $DELTA packets dropped in last second"
        fi
        
        PREV_DROPS=$CURRENT
    fi
    
    sleep 1
done
```

### Layer 5: Network Interface Drops

```bash
# Check interface statistics
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ip -s link show $DEFAULT_IF

# Output:
# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel
#     RX: bytes  packets  errors  dropped overrun mcast
#     123456789  987654   0       123     0       456
#     TX: bytes  packets  errors  dropped carrier collsns
#     234567890  876543   0       45      0       0
#              Drops ──────┘       └────── TX drops

# More detailed with ethtool
ethtool -S $DEFAULT_IF

# Output includes driver-specific counters:
# NIC statistics:
#      rx_packets: 987654
#      tx_packets: 876543
#      rx_bytes: 123456789
#      tx_bytes: 234567890
#      rx_errors: 0
#      tx_errors: 0
#      rx_dropped: 123
#      tx_dropped: 45
#      rx_fifo_errors: 0
#      tx_fifo_errors: 12  ← Buffer overflow in NIC
#      rx_missed_errors: 5  ← NIC couldn't keep up
```

### Comprehensive Loss Detection Script

```bash
#!/bin/bash
# detect-packet-loss.sh
# Multi-layer packet loss detection

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
INTERVAL=5

echo "===== Packet Loss Detection ====="
echo "Monitoring $INTERFACE every $INTERVAL seconds"
echo ""

# Initialize counters
declare -A PREV

# Get baseline
PREV[tcp_retrans]=$(awk '/^Tcp:/ && NR==2 {print $13}' /proc/net/snmp)
PREV[qdisc_drops]=$(tc -s qdisc show dev $INTERFACE | grep dropped | awk '{print $8}')
PREV[rx_drops]=$(ip -s link show $INTERFACE | grep -A 1 "RX:" | tail -1 | awk '{print $4}')
PREV[tx_drops]=$(ip -s link show $INTERFACE | grep -A 1 "TX:" | tail -1 | awk '{print $4}')

while true; do
    sleep $INTERVAL
    
    clear
    echo "===== Packet Loss Report (${INTERVAL}s interval) ====="
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # TCP Retransmissions
    CURRENT=$(awk '/^Tcp:/ && NR==2 {print $13}' /proc/net/snmp)
    DELTA=$((CURRENT - PREV[tcp_retrans]))
    if [ $DELTA -gt 0 ]; then
        echo "⚠ TCP Retransmissions: $DELTA (Layer 5: Network loss)"
    else
        echo "✓ TCP Retransmissions: 0"
    fi
    PREV[tcp_retrans]=$CURRENT
    
    # Qdisc Drops
    CURRENT=$(tc -s qdisc show dev $INTERFACE | grep dropped | awk '{print $8}')
    DELTA=$((CURRENT - PREV[qdisc_drops]))
    if [ $DELTA -gt 0 ]; then
        echo "⚠ Qdisc Drops: $DELTA (Layer 4: Queue overflow)"
    else
        echo "✓ Qdisc Drops: 0"
    fi
    PREV[qdisc_drops]=$CURRENT
    
    # RX Drops
    CURRENT=$(ip -s link show $INTERFACE | grep -A 1 "RX:" | tail -1 | awk '{print $4}')
    DELTA=$((CURRENT - PREV[rx_drops]))
    if [ $DELTA -gt 0 ]; then
        echo "⚠ Interface RX Drops: $DELTA (Layer 3: Receive buffer full)"
    else
        echo "✓ Interface RX Drops: 0"
    fi
    PREV[rx_drops]=$CURRENT
    
    # TX Drops
    CURRENT=$(ip -s link show $INTERFACE | grep -A 1 "TX:" | tail -1 | awk '{print $4}')
    DELTA=$((CURRENT - PREV[tx_drops]))
    if [ $DELTA -gt 0 ]; then
        echo "⚠ Interface TX Drops: $DELTA (Layer 3: Transmit buffer full)"
    else
        echo "✓ Interface TX Drops: 0"
    fi
    PREV[tx_drops]=$CURRENT
    
    echo ""
    echo "Current connections: $(ss -s | grep TCP: | awk '{print $2}')"
    echo "Memory usage: $(cat /proc/net/sockstat | grep TCP | awk '{print $11}') pages"
    echo ""
    echo "Press Ctrl+C to exit"
done
```

## Root Cause Analysis

### Identifying the Source of Problems

When issues are detected, systematically narrow down the cause:

#### Problem: High Retransmission Rate

```bash
# 1. Check if it's widespread or specific connections
ss -ti | grep -E "retrans|lost"

# Output shows per-connection retransmission info:
# retrans:0/5  ← 0 currently in flight, 5 total retransmitted

# 2. Check if it correlates with specific destinations
ss -ti dst 10.0.0.5 | grep retrans

# 3. Check RTT - high RTT suggests network issues
ss -ti | grep rtt
# rtt:50.5/25.2  ← Average/variance in ms

# 4. Check congestion window
ss -ti | grep cwnd
# cwnd:10 ssthresh:20  ← Current window and slow start threshold
```

#### Problem: Queue Drops

```bash
# 1. Identify which queue is dropping
tc -s qdisc show

# 2. Check if queue is persistently full
tc -s qdisc show | grep backlog
# backlog 45p 67500b  ← 45 packets, 67.5KB queued

# 3. Monitor queue depth over time
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
watch -n 1 "tc -s qdisc show dev $DEFAULT_IF | grep backlog"

# 4. If backlog consistently high → queue too small or link congested
# If drops but low backlog → burst exceeds queue capacity
```

#### Problem: Interface Drops

```bash
# 1. Check RX vs TX drops
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
ip -s link show $DEFAULT_IF | grep -A 2 "X:"

# 2. RX drops → incoming traffic too fast for CPU to process
#    Solutions:
#    - Increase NIC ring buffer: ethtool -G eth0 rx 4096
#    - Enable RSS/RPS (multi-queue)
#    - Reduce interrupt rate with ethtool -C

# 3. TX drops → outgoing traffic exceeds link capacity
#    Solutions:
#    - Increase NIC ring buffer: ethtool -G eth0 tx 4096
#    - Reduce qdisc queue length (counter-intuitive but reduces latency)
#    - Enable TSO/GSO offloading

# 4. Check for hardware errors
ethtool -S $DEFAULT_IF | grep -i error
```

### Correlation Analysis

Often problems have multiple contributing factors. Check correlations:

```bash
#!/bin/bash
# correlate-issues.sh
# Look for correlation between different metrics

INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
LOG_FILE="/var/log/network-metrics.log"

# Collect metrics
while true; do
    TIMESTAMP=$(date +%s)
    TCP_MEM=$(cat /proc/net/sockstat | grep TCP | awk '{print $11}')
    RETRANS=$(awk '/^Tcp:/ && NR==2 {print $13}' /proc/net/snmp)
    QDISC_DROPS=$(tc -s qdisc show dev $INTERFACE | grep dropped | awk '{print $8}')
    CONNECTIONS=$(ss -s | grep TCP: | awk '{print $2}')
    
    echo "$TIMESTAMP $TCP_MEM $RETRANS $QDISC_DROPS $CONNECTIONS" >> $LOG_FILE
    
    # Analyze last 60 entries (5 minutes at 5-second intervals)
    if [ $(wc -l < $LOG_FILE) -ge 60 ]; then
        echo ""
        echo "===== Correlation Analysis ====="
        
        # Calculate correlation between memory and retransmissions
        tail -60 $LOG_FILE | awk '{
            sum_mem += $2; sum_retrans += $3
            sum_mem_sq += $2*$2; sum_retrans_sq += $3*$3
            sum_cross += $2*$3
            n++
        } END {
            if (n > 1) {
                corr = (n*sum_cross - sum_mem*sum_retrans) / 
                       sqrt((n*sum_mem_sq - sum_mem^2) * (n*sum_retrans_sq - sum_retrans^2))
                print "Memory vs Retransmissions correlation: " corr
                if (corr > 0.7) print "  → Strong positive correlation"
                else if (corr < -0.7) print "  → Strong negative correlation"
                else print "  → Weak correlation"
            }
        }'
    fi
    
    sleep 5
done
```

## Application-Level Detection

### Using strace to Detect Blocking

```bash
# Trace system calls for a process
strace -p <PID> -e trace=network -T -tt

# Output shows timing:
# 10:15:30.123456 write(3, "...", 8192) = 8192 <0.000123>
#                                                ^^^^^^^^
#                                         Time spent in syscall

# If write() takes milliseconds → buffer full, waiting for ACKs

# Trace all socket operations with timing
strace -p <PID> -e trace=socket,connect,accept,send,recv,sendto,recvfrom,write,read -T

# Count blocked write calls
strace -p <PID> -e trace=write -c
# Output:
# % time     seconds  usecs/call     calls    errors syscall
# 100.00    5.234567         523     10000         0 write
#                      ^^^
#                 Average 523 microseconds per write
# If average is high (>1ms) → blocking issues
```

### Using ss for Application Diagnosis

```bash
# Show sockets for specific process
ss -tp | grep "pid=12345"

# Show detailed socket state
ss -tem dst 10.0.0.5

# Output includes:
# timer:(on,5min30sec,0)  ← Retransmission timer active
# rto:1000                ← Retransmission timeout = 1 second
# ato:40                  ← ACK timeout
# cwnd:10                 ← Congestion window = 10 MSS
# ssthresh:20             ← Slow start threshold

# If timer shows retransmissions → packet loss
# If cwnd very small → recovering from congestion
# If rto very high → poor network conditions
```

## Performance Baseline and Anomaly Detection

### Establishing Baselines

```bash
#!/bin/bash
# baseline-collector.sh
# Collect network performance baseline over 24 hours

OUTPUT_DIR="/var/log/network-baseline"
mkdir -p $OUTPUT_DIR

INTERVAL=60  # 1 minute

while true; do
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    
    # Collect comprehensive stats
    {
        echo "=== $TIMESTAMP ==="
        
        # TCP statistics
        netstat -s | grep -A 20 "^Tcp:"
        
        # Socket memory
        cat /proc/net/sockstat
        
        # Interface stats  
        ip -s link show
        
        # Qdisc stats
        tc -s qdisc show
        
        # Connection summary
        ss -s
        
    } >> "$OUTPUT_DIR/baseline-$(date +%Y%m%d).log"
    
    sleep $INTERVAL
done
```

### Anomaly Detection

```bash
#!/bin/bash
# detect-anomalies.sh
# Compare current metrics against baseline

BASELINE_DIR="/var/log/network-baseline"
BASELINE_FILE="$BASELINE_DIR/baseline-$(date +%Y%m%d).log"

if [ ! -f "$BASELINE_FILE" ]; then
    echo "No baseline found for today. Run baseline-collector.sh first."
    exit 1
fi

# Calculate baseline statistics
BASELINE_RETRANS=$(grep "segments retransmitted" "$BASELINE_FILE" | \
    awk '{sum+=$1; n++} END {print sum/n}')

# Get current value
CURRENT_RETRANS=$(netstat -s | grep "segments retransmitted" | awk '{print $1}')

# Calculate deviation
DEVIATION=$(echo "scale=2; ($CURRENT_RETRANS - $BASELINE_RETRANS) / $BASELINE_RETRANS * 100" | bc)

echo "Retransmission Analysis:"
echo "  Baseline average: $BASELINE_RETRANS"
echo "  Current: $CURRENT_RETRANS"
echo "  Deviation: $DEVIATION%"

if (( $(echo "$DEVIATION > 50" | bc -l) )); then
    echo "  ⚠ ANOMALY: Retransmissions 50% higher than baseline"
elif (( $(echo "$DEVIATION > 20" | bc -l) )); then
    echo "  ⚠ WARNING: Retransmissions 20% higher than baseline"
else
    echo "  ✓ Normal"
fi
```

## Troubleshooting Common Scenarios

### Scenario 1: Sudden Latency Spike

```bash
# Quick diagnostic sequence

# 1. Check if memory pressure
cat /proc/net/sockstat | grep mem

# 2. Check for retransmissions spike
nstat | grep Retrans

# 3. Check queue backlog
tc -s qdisc show | grep backlog

# 4. Check for new connections flood
ss -s

# 5. Look for specific bad connection
ss -ti | sort -k5 -t: | grep -A 1 "rto:[0-9][0-9][0-9][0-9]"  # RTO > 1 sec

# 6. Check system load
uptime
top -b -n 1 | head -20
```

### Scenario 2: Gradual Performance Degradation

```bash
# Indicators of slow leak or resource exhaustion

# 1. Memory growing over time
watch -n 60 'cat /proc/net/sockstat | grep mem'

# 2. Orphaned sockets accumulating
watch -n 60 'cat /proc/net/sockstat | grep orphan'

# 3. TIME-WAIT sockets piling up
watch -n 60 'ss -s | grep TIME-WAIT'

# 4. Check for socket leaks in application
lsof -p <PID> | grep -c socket
# Run periodically, if count grows → socket leak

# 5. Check file descriptor usage
cat /proc/<PID>/limits | grep "open files"
ls /proc/<PID>/fd | wc -l
```

### Scenario 3: Intermittent Connection Failures

```bash
# Capture failure events

# 1. Enable detailed TCP logging
echo 1 > /proc/sys/net/ipv4/tcp_debug
# WARNING: High overhead, use briefly

# 2. Monitor connection failures
watch -n 1 'netstat -s | grep -i fail'

# 3. Capture failed SYN attempts
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tcpdump -i $DEFAULT_IF 'tcp[tcpflags] & tcp-syn != 0' -w /tmp/syn-capture.pcap

# 4. Check listen queue overflows
netstat -s | grep "listen queue"
# SYNs to LISTEN sockets dropped: 123
# times the listen queue of a socket overflowed: 45

# 5. Increase listen backlog if needed
# In application: listen(sockfd, 1024);  // Increase from default 128
```

## Automated Monitoring and Alerting

### Systemd Service for Continuous Monitoring

```bash
# Create monitoring service
cat << 'EOF' | sudo tee /etc/systemd/system/network-monitor.service
[Unit]
Description=Network Performance Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/network-monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create monitoring script
cat << 'EOF' | sudo tee /usr/local/bin/network-monitor.sh
#!/bin/bash
# Continuous network monitoring with alerting

LOG_FILE="/var/log/network-monitor.log"
ALERT_THRESHOLD_RETRANS=100  # Alert if >100 retrans/min
ALERT_THRESHOLD_MEM=85       # Alert if >85% of high threshold

while true; do
    # Collect metrics
    RETRANS=$(awk '/^Tcp:/ && NR==2 {print $13}' /proc/net/snmp)
    TCP_MEM=$(cat /proc/net/sockstat | grep TCP | awk '{print $11}')
    TCP_HIGH=$(cat /proc/sys/net/ipv4/tcp_mem | awk '{print $3}')
    PCT_MEM=$(echo "scale=1; $TCP_MEM * 100 / $TCP_HIGH" | bc)
    
    # Check thresholds
    if [ ! -z "$PREV_RETRANS" ]; then
        RETRANS_RATE=$((RETRANS - PREV_RETRANS))
        
        if [ $RETRANS_RATE -gt $ALERT_THRESHOLD_RETRANS ]; then
            MSG="HIGH RETRANSMISSION RATE: $RETRANS_RATE/min"
            echo "$(date): $MSG" >> $LOG_FILE
            logger -p user.warning -t network-monitor "$MSG"
        fi
    fi
    
    if (( $(echo "$PCT_MEM > $ALERT_THRESHOLD_MEM" | bc -l) )); then
        MSG="HIGH TCP MEMORY: ${PCT_MEM}% of high threshold"
        echo "$(date): $MSG" >> $LOG_FILE
        logger -p user.warning -t network-monitor "$MSG"
    fi
    
    PREV_RETRANS=$RETRANS
    
    sleep 60
done
EOF

sudo chmod +x /usr/local/bin/network-monitor.sh
sudo systemctl daemon-reload
sudo systemctl enable network-monitor.service
sudo systemctl start network-monitor.service
```

### Integration with Monitoring Systems

```bash
# Export metrics for Prometheus/Grafana

cat << 'EOF' > /usr/local/bin/network-metrics-exporter.sh
#!/bin/bash
# Export network metrics in Prometheus format

METRICS_FILE="/var/lib/node_exporter/textfile_collector/network.prom"

while true; do
    {
        echo "# HELP tcp_retransmit_segments Total TCP segments retransmitted"
        echo "# TYPE tcp_retransmit_segments counter"
        echo "tcp_retransmit_segments $(awk '/^Tcp:/ && NR==2 {print $13}' /proc/net/snmp)"
        
        echo "# HELP tcp_memory_pages TCP memory usage in pages"
        echo "# TYPE tcp_memory_pages gauge"
        echo "tcp_memory_pages $(cat /proc/net/sockstat | grep TCP | awk '{print $11}')"
        
        echo "# HELP tcp_connections Total TCP connections"
        echo "# TYPE tcp_connections gauge"
        echo "tcp_connections $(ss -s | grep TCP: | awk '{print $2}')"
        
    } > "$METRICS_FILE.$$"
    
    mv "$METRICS_FILE.$$" "$METRICS_FILE"
    
    sleep 15
done
EOF

chmod +x /usr/local/bin/network-metrics-exporter.sh
```

## Key Takeaways

1. **Layered Diagnostics**: Problems can occur at multiple layers
   - Start with quick checks across all layers
   - Drill down into specific layer showing issues
   - Use appropriate tools for each layer

2. **Memory Pressure Indicators**: Multiple ways to detect
   - /proc/net/sockstat for current usage
   - /proc/net/protocols for pressure state
   - dmesg for kernel warnings
   - Per-socket inspection with ss

3. **Packet Loss Sources**: Different layers, different causes
   - TCP retransmissions: Network path issues
   - Qdisc drops: Local queue overflow
   - Interface drops: Hardware/driver issues
   - Each requires different remediation

4. **Correlation Matters**: Single metrics can be misleading
   - High retransmissions with high memory: Congestion
   - High retransmissions with low memory: Path issues
   - Must look at multiple indicators together

5. **Baseline and Monitor**: Know what's normal
   - Establish performance baselines
   - Detect anomalies automatically
   - Alert on deviations from normal

6. **Root Cause Analysis**: Systematic approach
   - Don't jump to solutions
   - Collect evidence at each layer
   - Correlate timing of issues
   - Verify fixes with measurements

7. **Automated Monitoring**: Manual checks don't scale
   - Use systemd services for continuous monitoring
   - Export metrics to monitoring systems
   - Set up alerting thresholds
   - Log for historical analysis

## What's Next

With diagnostic techniques established, the next documents cover optimization and validation:

- **[RTT-Driven Buffer Sizing](07-rtt-buffer-sizing.md)**: Calculate optimal buffers based on measurements
- **[Low-Latency System Profile](08-low-latency-profile.md)**: Complete system configuration checklist
- **[Complete Validation Procedure](09-validation-procedure.md)**: Systematic testing methodology

---

**Previous**: [Queueing and Congestion Control](05-queueing-congestion.md)  
**Next**: [RTT-Driven Buffer Sizing and BDP Calculations](07-rtt-buffer-sizing.md)
