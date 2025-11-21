# Low-Latency System Profile

## Overview

Achieving consistent low latency for time-sensitive message delivery requires holistic system configuration. A single misconfigured parameter can undermine all other optimizations. This document provides a complete, tested configuration profile for RHEL/OEL 8 systems optimized for minimizing network latency and packet loss.

## Deployment Scenarios

This profile covers configuration for two distinct deployment scenarios:

**Backend Components (Datacenter)**
- Network: Low-latency LAN within single datacenter or availability zone
- RTT: 1-5ms
- Conditions: Stable, low packet loss
- Focus: Minimize absolute latency
- Buffer Strategy: Small buffers (64-128KB) to reduce queuing delay

**Customer-Facing Components (Internet)**
- Network: Internet connectivity from global locations
- RTT: 50-200ms
- Conditions: Variable jitter, potential packet loss, network heterogeneity
- Focus: Minimize latency variance, handle bursts, ensure delivery
- Buffer Strategy: Moderate buffers (256-512KB) for resilience

The profile uses Internet-oriented settings as defaults for broader applicability, but includes notes on datacenter-specific alternatives for environments requiring absolute minimum latency.

This configuration targets minimal latency variance with predictable performance under load, while maintaining reliability for small message delivery (1-2KB per message).

## Configuration Philosophy

### Design Principles

```
┌─────────────────────────────────────────────────────────────────┐
│ LOW-LATENCY CONFIGURATION PRINCIPLES                            │
│                                                                 │
│ 1. Minimize Queuing                                             │
│    └─ Small buffers, short queues, fast processing              │
│                                                                 │
│ 2. Reduce Variability                                           │
│    └─ Consistent behavior more important than peak throughput   │
│                                                                 │
│ 3. Optimize Critical Path                                       │
│    └─ Focus on hot path (data transmission), not edge cases     │
│                                                                 │
│ 4. Measure Everything                                           │
│    └─ Baseline, change one thing, measure, validate             │
│                                                                 │
│ 5. Fail Fast                                                    │
│    └─ Quick error detection better than slow retries            │
└─────────────────────────────────────────────────────────────────┘
```

### Trade-offs Accepted

```
Optimizing for minimal latency means accepting these trade-offs:

Maximum Throughput:
  ✗ May not achieve theoretical maximum bandwidth
  ✓ Consistent, predictable latency more important for small messages

Burst Handling:
  ✗ Smaller queues may drop packets during extreme bursts
  ✓ Normal traffic experiences lower queuing delay

CPU Utilization:
  ✗ More CPU work per packet (immediate processing, no batching)
  ✓ Faster response to network events

Memory Efficiency:
  ✗ May allocate buffers not fully utilized
  ✓ Predictable behavior and performance guarantees

Message Delivery Semantics:
  ✗ Configuration is not optimal for maximum file transfer speed
  ✓ Well-suited for small, time-sensitive messages
```

## Complete System Configuration

### Network Interface Configuration

```bash
#!/bin/bash
# configure-network-interface.sh
# Optimize network interface for low latency

# Detect default network interface dynamically
if [ -z "$1" ]; then
    INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "Error: Could not determine default network interface"
        echo "Usage: $0 [interface_name]"
        exit 1
    fi
else
    INTERFACE="$1"
fi

echo "===== Network Interface Configuration ====="
echo "Interface: $INTERFACE"
echo ""

# 1. Set MTU (standard 1500 for universal compatibility)
echo "[1/8] Setting MTU..."
sudo ip link set $INTERFACE mtu 1500

# 2. Reduce TX queue length (lower buffering)
echo "[2/8] Reducing TX queue length..."
sudo ip link set $INTERFACE txqueuelen 500
# Default: 1000
# Low-latency: 500
# At 1 Gbps: 500 packets = 6ms max queuing delay

# 3. Configure ring buffers (reduce hardware buffering)
echo "[3/8] Configuring ring buffers..."
if ethtool -g $INTERFACE &>/dev/null; then
    sudo ethtool -G $INTERFACE rx 256 tx 256 2>/dev/null || \
        echo "    Ring buffer adjustment not supported by NIC"
else
    echo "    ethtool not available or NIC doesn't support ring config"
fi

# 4. Disable interrupt coalescing (reduce latency)
echo "[4/8] Disabling interrupt coalescing..."
sudo ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null || \
    echo "    Interrupt coalescing control not supported"
# Note: This increases CPU usage but reduces latency

# 5. Enable hardware offloading (careful testing required)
echo "[5/8] Configuring hardware offloading..."
# TSO/GSO can help with large transfers
sudo ethtool -K $INTERFACE tso on gso on 2>/dev/null || true
# Disable LRO (can add latency)
sudo ethtool -K $INTERFACE lro off 2>/dev/null || true
# GRO is generally okay for receive side
sudo ethtool -K $INTERFACE gro on 2>/dev/null || true

# 6. Set interrupt affinity (if multi-core)
echo "[6/8] Setting interrupt affinity..."
# Find IRQ for interface
IRQ=$(grep $INTERFACE /proc/interrupts | awk '{print $1}' | sed 's/://')
if [ ! -z "$IRQ" ]; then
    # Pin to specific CPU core (adjust based on topology)
    echo "2" | sudo tee /proc/irq/$IRQ/smp_affinity_list > /dev/null
    echo "    IRQ $IRQ pinned to CPU 2"
else
    echo "    Could not determine IRQ"
fi

# 7. Disable power management features
echo "[7/8] Disabling power management..."
sudo ethtool -s $INTERFACE speed 1000 duplex full autoneg off 2>/dev/null || \
    echo "    Speed/duplex configuration not supported"

# 8. Set qdisc to fq (fair queue with pacing)
echo "[8/8] Configuring qdisc..."
sudo tc qdisc replace dev $INTERFACE root fq pacing

echo ""
echo "===== Configuration Complete ====="
echo ""
echo "Verify with:"
echo "  ip link show $INTERFACE"
echo "  ethtool $INTERFACE"
echo "  ethtool -g $INTERFACE"
echo "  tc qdisc show dev $INTERFACE"
```

### Kernel Network Parameters

```bash
#!/bin/bash
# configure-kernel-network.sh
# Complete kernel parameter tuning for low latency

cat << 'EOF' | sudo tee /etc/sysctl.d/99-low-latency-network.conf
# ============================================================
# Low-Latency Network Configuration for Payment Systems
# Target: Sub-10ms transaction latency
# Applied: $(date)
# ============================================================

# ------------------------------------------------------------
# TCP Congestion Control
# ------------------------------------------------------------
# Use BBR for optimal latency (requires kernel 4.9+)
net.ipv4.tcp_congestion_control = bbr

# Enable ECN (Explicit Congestion Notification)
net.ipv4.tcp_ecn = 1

# ------------------------------------------------------------
# Socket Buffer Sizing
# ------------------------------------------------------------
# Maximum socket buffer sizes
# Internet (50-200ms RTT): 4MB for 1-2KB messages
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304

# TCP auto-tuning (min, default, max in bytes)
# Sized for 1-2KB message delivery
# Backend (datacenter, 1-5ms RTT): smaller buffers to minimize latency
#   Min: 4KB, Default: 64KB, Max: 512KB (0.4× BDP for 1Gbps)
# Internet (50-200ms RTT): larger buffers to handle variable conditions
#   Min: 4KB, Default: 256KB, Max: 4MB (0.5-1× BDP for 1Gbps @ 50ms)
#
# Using Internet settings as default (broader applicability)
net.ipv4.tcp_rmem = 4096 262144 4194304
net.ipv4.tcp_wmem = 4096 262144 4194304

# Enable TCP window scaling
net.ipv4.tcp_window_scaling = 1

# ------------------------------------------------------------
# TCP Memory Management
# ------------------------------------------------------------
# TCP memory limits (in pages, 4KB each)
# Low: 2GB, Pressure: 4GB, High: 8GB
net.ipv4.tcp_mem = 524288 1048576 2097152

# Allow more orphaned sockets
net.ipv4.tcp_max_orphans = 131072

# Enable TCP auto-tuning of receive buffer
net.ipv4.tcp_moderate_rcvbuf = 1

# ------------------------------------------------------------
# TCP Connection Management
# ------------------------------------------------------------
# Reduce TIME-WAIT duration (faster port reuse)
net.ipv4.tcp_fin_timeout = 15
# Default: 60 seconds
# Low-latency: 15-30 seconds

# Allow TIME-WAIT socket reuse
net.ipv4.tcp_tw_reuse = 1

# Increase max number of open files
fs.file-max = 2097152

# Increase max connection backlog
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000

# Increase SYN backlog
net.ipv4.tcp_max_syn_backlog = 8192

# ------------------------------------------------------------
# TCP Fast Open and Recovery
# ------------------------------------------------------------
# Enable TCP Fast Open (requires kernel 3.7+)
net.ipv4.tcp_fastopen = 3
# 1: Enable for outgoing connections
# 2: Enable for listening sockets
# 3: Enable both

# Disable slow start after idle
net.ipv4.tcp_slow_start_after_idle = 0

# Enable early retransmit (RFC 5827)
net.ipv4.tcp_early_retrans = 3

# Enable forward RTO-Recovery (RFC 5682)
net.ipv4.tcp_recovery = 1

# ------------------------------------------------------------
# TCP Keepalive
# ------------------------------------------------------------
# More aggressive keepalive for faster dead connection detection
net.ipv4.tcp_keepalive_time = 300
# Default: 7200 (2 hours)
# Low-latency: 300 (5 minutes)

net.ipv4.tcp_keepalive_intvl = 30
# Default: 75 seconds
# Low-latency: 30 seconds

net.ipv4.tcp_keepalive_probes = 3
# Default: 9
# Low-latency: 3

# ------------------------------------------------------------
# TCP Timestamps and SACK
# ------------------------------------------------------------
# Enable TCP timestamps (for RTT measurement)
net.ipv4.tcp_timestamps = 1

# Enable SACK (Selective Acknowledgment)
net.ipv4.tcp_sack = 1

# Enable DSACK (Duplicate SACK)
net.ipv4.tcp_dsack = 1

# Enable FACK (Forward Acknowledgment)
net.ipv4.tcp_fack = 1

# ------------------------------------------------------------
# IPv4 Routing and Forwarding
# ------------------------------------------------------------
# Disable IP forwarding (not a router)
net.ipv4.ip_forward = 0

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ------------------------------------------------------------
# Core Network Settings
# ------------------------------------------------------------
# Increase local port range
net.ipv4.ip_local_port_range = 10000 65535

# Disable IPv6 (if not used)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1

# ------------------------------------------------------------
# ARP Cache Settings
# ------------------------------------------------------------
# Increase ARP cache size
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# ------------------------------------------------------------
# UDP Settings
# ------------------------------------------------------------
# UDP buffer sizes
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# UDP memory (in pages)
net.ipv4.udp_mem = 524288 1048576 2097152

# ------------------------------------------------------------
# Other Memory Settings
# ------------------------------------------------------------
# Option memory limit
net.core.optmem_max = 65536

# Default send/receive buffer sizes
net.core.rmem_default = 262144
net.core.wmem_default = 262144

EOF

# Apply settings
sudo sysctl -p /etc/sysctl.d/99-low-latency-network.conf

echo ""
echo "===== Kernel Parameters Applied ====="
echo ""
echo "Verify critical settings:"
echo "  Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  ECN: $(sysctl -n net.ipv4.tcp_ecn)"
echo "  TCP FO: $(sysctl -n net.ipv4.tcp_fastopen)"
echo "  Slow start after idle: $(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
```

### CPU and Interrupt Optimization

```bash
#!/bin/bash
# configure-cpu-interrupts.sh
# Optimize CPU scheduling and interrupt handling

echo "===== CPU and Interrupt Optimization ====="
echo ""

# 1. Set CPU governor to performance
echo "[1/5] Setting CPU governor to performance..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee $cpu > /dev/null
done
echo "    CPU governor set to performance"

# 2. Disable CPU C-states (reduce wakeup latency)
echo "[2/5] Disabling deep C-states..."
# This typically requires BIOS setting, but can hint via kernel
sudo sh -c 'echo 1 > /sys/devices/system/cpu/cpu*/cpuidle/state*/disable' 2>/dev/null || \
    echo "    C-state control not available (check BIOS)"

# 3. Configure RPS/RFS (Receive Packet Steering / Flow Steering)
echo "[3/5] Configuring RPS/RFS..."

# Detect default network interface dynamically if not provided
if [ -z "$1" ]; then
    INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "    Warning: Could not determine default network interface, skipping RPS/RFS"
        echo "    Usage: $0 [interface_name]"
    fi
else
    INTERFACE="$1"
fi

if [ ! -z "$INTERFACE" ]; then
    # Get number of CPUs
    NUM_CPUS=$(nproc)

    # Calculate RPS mask (all CPUs except CPU 0)
    RPS_MASK=$(printf "%x" $((2**NUM_CPUS - 2)))

    # Apply RPS
    for rps_file in /sys/class/net/$INTERFACE/queues/rx-*/rps_cpus; do
        echo "$RPS_MASK" | sudo tee $rps_file > /dev/null
    done

    # Configure RFS
    sudo sysctl -w net.core.rps_sock_flow_entries=32768
    for rps_flow_cnt in /sys/class/net/$INTERFACE/queues/rx-*/rps_flow_cnt; do
        echo 2048 | sudo tee $rps_flow_cnt > /dev/null
    done
    echo "    RPS/RFS configured"
fi

# 4. Set IRQ affinity for network interface
echo "[4/5] Setting IRQ affinity..."

# Detect interface if not already set
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
fi

if [ ! -z "$INTERFACE" ]; then
    IRQ=$(grep $INTERFACE /proc/interrupts | awk '{print $1}' | sed 's/://' | head -1)
    if [ ! -z "$IRQ" ]; then
        # Dedicate specific CPU cores to network processing
        # Adjust based on system topology
        echo "2-3" | sudo tee /proc/irq/$IRQ/smp_affinity_list > /dev/null
        echo "    Network IRQ $IRQ pinned to CPUs 2-3"
    else
        echo "    Could not determine IRQ for $INTERFACE"
    fi
else
    echo "    Warning: Could not determine default network interface"
fi

# 5. Configure kernel scheduler
echo "[5/5] Configuring kernel scheduler..."
cat << 'EOF' | sudo tee /etc/sysctl.d/99-scheduler.conf
# Scheduler settings for low latency

# Reduce scheduler migration cost
kernel.sched_migration_cost_ns = 5000000

# Preemption settings
kernel.sched_min_granularity_ns = 1000000
kernel.sched_wakeup_granularity_ns = 2000000

# Autogroup scheduling (helps isolate workloads)
kernel.sched_autogroup_enabled = 1
EOF

sudo sysctl -p /etc/sysctl.d/99-scheduler.conf

echo ""
echo "===== CPU Optimization Complete ====="
```

### System Limits and Security

```bash
#!/bin/bash
# configure-system-limits.sh
# Set system limits for high-performance networking

echo "===== System Limits Configuration ====="
echo ""

# 1. Configure limits.conf
echo "[1/3] Configuring /etc/security/limits.conf..."
cat << 'EOF' | sudo tee -a /etc/security/limits.conf

# Low-latency network application limits
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     131072
*    hard    nproc     131072
*    soft    memlock   unlimited
*    hard    memlock   unlimited
EOF

# 2. Configure systemd limits
echo "[2/3] Configuring systemd limits..."
sudo mkdir -p /etc/systemd/system.conf.d
cat << 'EOF' | sudo tee /etc/systemd/system.conf.d/99-limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=131072
DefaultLimitMEMLOCK=infinity
EOF

sudo systemctl daemon-reexec

# 3. Configure sysctl for system limits
echo "[3/3] Configuring kernel limits..."
cat << 'EOF' | sudo tee /etc/sysctl.d/99-system-limits.conf
# System-wide limits

# Maximum number of open files
fs.file-max = 2097152

# Maximum number of inotify watches
fs.inotify.max_user_watches = 524288

# Shared memory settings
kernel.shmmax = 68719476736
kernel.shmall = 4294967296
EOF

sudo sysctl -p /etc/sysctl.d/99-system-limits.conf

echo ""
echo "===== System Limits Applied ====="
echo ""
echo "Verify with:"
echo "  ulimit -a"
echo "  sysctl fs.file-max"
```

### Disable Unnecessary Services

```bash
#!/bin/bash
# disable-unnecessary-services.sh
# Disable services that may interfere with low-latency operation

echo "===== Disabling Unnecessary Services ====="
echo ""

# List of services to disable (adjust based on requirements)
SERVICES_TO_DISABLE=(
    "firewalld"          # Use iptables instead for better control
    "postfix"            # If not sending email
    "cups"               # Print service
    "avahi-daemon"       # Zeroconf networking
    "bluetooth"          # Bluetooth
    "ModemManager"       # Modem management
)

for service in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled $service &>/dev/null; then
        echo "Disabling $service..."
        sudo systemctl stop $service
        sudo systemctl disable $service
    else
        echo "$service not installed or already disabled"
    fi
done

echo ""
echo "===== Services Disabled ====="
echo ""
echo "WARNING: Review disabled services to ensure they're not needed"
echo "To re-enable: systemctl enable <service> && systemctl start <service>"
```

### Transparent Huge Pages (THP)

```bash
#!/bin/bash
# configure-transparent-hugepages.sh
# THP can cause latency spikes - disable or use madvise mode

echo "===== Transparent Huge Pages Configuration ====="
echo ""

# Check current setting
CURRENT=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
echo "Current THP setting: $CURRENT"
echo ""

# Recommended: madvise (applications opt-in) or never (fully disabled)
# For payment systems: never (most predictable)

echo "Setting THP to 'never'..."
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null

# Make permanent via GRUB
if ! grep -q "transparent_hugepage=never" /etc/default/grub; then
    echo "Adding to GRUB configuration..."
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="transparent_hugepage=never /' /etc/default/grub
    
    # Update GRUB
    if [ -f /boot/grub2/grub.cfg ]; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    elif [ -f /boot/efi/EFI/redhat/grub.cfg ]; then
        sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
    fi
    
    echo "GRUB updated. Reboot required for permanent change."
fi

echo ""
echo "THP disabled. Current setting:"
cat /sys/kernel/mm/transparent_hugepage/enabled
```

## Application-Level Configuration

### Socket Options Template

For applications to use optimal settings:

```c
// application-socket-config.h
// Socket configuration template for low-latency applications

#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>

int configure_low_latency_socket(int sockfd) {
    int optval;
    socklen_t optlen = sizeof(optval);

    // 1. Set send buffer size
    // For 1-2KB messages over Internet (50-200ms RTT): 256KB provides good resilience
    // For 1-2KB messages over datacenter (1-5ms RTT): 64KB sufficient for latency
    // Using larger value (256KB) for broader compatibility
    optval = 262144;
    if (setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF,
                   &optval, sizeof(optval)) < 0) {
        perror("SO_SNDBUF");
        return -1;
    }

    // 2. Set receive buffer size (256KB for consistency)
    optval = 262144;
    if (setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF,
                   &optval, sizeof(optval)) < 0) {
        perror("SO_RCVBUF");
        return -1;
    }
    
    // 3. Disable Nagle's algorithm (critical for low latency)
    optval = 1;
    if (setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY,
                   &optval, sizeof(optval)) < 0) {
        perror("TCP_NODELAY");
        return -1;
    }
    
    // 4. Set congestion control to BBR (if available)
    const char *algo = "bbr";
    if (setsockopt(sockfd, IPPROTO_TCP, TCP_CONGESTION,
                   algo, strlen(algo)) < 0) {
        // Fall back to default if BBR not available
        perror("TCP_CONGESTION (non-fatal)");
    }
    
    // 5. Enable TCP_QUICKACK (disable delayed ACKs)
    optval = 1;
    if (setsockopt(sockfd, IPPROTO_TCP, TCP_QUICKACK,
                   &optval, sizeof(optval)) < 0) {
        perror("TCP_QUICKACK (non-fatal)");
    }
    
    // 6. Set TCP_USER_TIMEOUT (faster failure detection)
    optval = 5000;  // 5 seconds
    if (setsockopt(sockfd, IPPROTO_TCP, TCP_USER_TIMEOUT,
                   &optval, sizeof(optval)) < 0) {
        perror("TCP_USER_TIMEOUT (non-fatal)");
    }
    
    // 7. Enable keepalive
    optval = 1;
    if (setsockopt(sockfd, SOL_SOCKET, SO_KEEPALIVE,
                   &optval, sizeof(optval)) < 0) {
        perror("SO_KEEPALIVE");
        return -1;
    }
    
    return 0;
}

// For server (listening) sockets
int configure_low_latency_listen_socket(int listenfd) {
    int optval;

    // 1. Set receive buffer BEFORE listen()
    // Inherited by accepted connections
    // 256KB handles 1-2KB messages well across both deployment scenarios
    optval = 262144;
    if (setsockopt(listenfd, SOL_SOCKET, SO_RCVBUF,
                   &optval, sizeof(optval)) < 0) {
        perror("SO_RCVBUF");
        return -1;
    }
    
    // 2. Enable socket reuse
    optval = 1;
    if (setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR,
                   &optval, sizeof(optval)) < 0) {
        perror("SO_REUSEADDR");
        return -1;
    }
    
    // 3. Set TCP defer accept (don't wake until data arrives)
    optval = 1;  // 1 second
    if (setsockopt(listenfd, IPPROTO_TCP, TCP_DEFER_ACCEPT,
                   &optval, sizeof(optval)) < 0) {
        perror("TCP_DEFER_ACCEPT (non-fatal)");
    }
    
    return 0;
}
```

## Complete Deployment Script

### Master Configuration Script

```bash
#!/bin/bash
# deploy-low-latency-profile.sh
# Complete system configuration for low-latency message delivery

set -e

# Detect default network interface dynamically
if [ -z "$1" ]; then
    INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "Error: Could not determine default network interface"
        echo "Usage: $0 [interface_name]"
        exit 1
    fi
else
    INTERFACE="$1"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================="
echo "  Low-Latency System Profile Deployment"
echo "  Target: Time-Sensitive Message Delivery"
echo "  Interface: $INTERFACE"
echo "======================================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo"
    exit 1
fi

# Backup current configuration
BACKUP_DIR="/root/network-config-backup-$(date +%Y%m%d-%H%M%S)"
echo "Creating backup in $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/sysctl.d/*.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/security/limits.conf "$BACKUP_DIR/" 2>/dev/null || true
echo "✓ Backup created"
echo ""

# Deployment steps
STEP=1
TOTAL=8

echo "[$STEP/$TOTAL] Configuring network interface..."
# Interface configuration inline
ip link set $INTERFACE mtu 1500
ip link set $INTERFACE txqueuelen 500
ethtool -G $INTERFACE rx 256 tx 256 2>/dev/null || echo "  Ring buffer config not supported"
ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null || echo "  Interrupt coalescing not supported"
tc qdisc replace dev $INTERFACE root fq pacing
echo "✓ Interface configured"
echo ""
((STEP++))

echo "[$STEP/$TOTAL] Applying kernel network parameters..."
# Apply the kernel network configuration from earlier section
/bin/bash -c 'cat << "NETCONF" > /etc/sysctl.d/99-low-latency-network.conf
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 8388608
net.ipv4.tcp_wmem = 4096 262144 8388608
net.ipv4.tcp_mem = 524288 1048576 2097152
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
fs.file-max = 2097152
NETCONF'
sysctl -p /etc/sysctl.d/99-low-latency-network.conf > /dev/null
echo "✓ Kernel parameters applied"
echo ""
((STEP++))

echo "[$STEP/$TOTAL] Optimizing CPU and interrupts..."
# CPU governor
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov" ] && echo performance > $gov
done
echo "✓ CPU optimized"
echo ""
((STEP++))

echo "[$STEP/$TOTAL] Configuring system limits..."
cat << 'LIMITS' >> /etc/security/limits.conf

# Low-latency network limits
*    soft    nofile    1048576
*    hard    nofile    1048576
LIMITS
echo "✓ System limits configured"
echo ""
((STEP++))

echo "[$STEP/$TOTAL] Disabling Transparent Huge Pages..."
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
if ! grep -q "transparent_hugepage=never" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="transparent_hugepage=never /' /etc/default/grub
fi
echo "✓ THP disabled"
echo ""
((STEP++))

echo "[$STEP/$TOTAL] Creating persistence service..."
cat << SERVICE > /etc/systemd/system/low-latency-network.service
[Unit]
Description=Low-Latency Network Configuration
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'tc qdisc replace dev $INTERFACE root fq pacing'
ExecStart=/bin/bash -c 'ip link set $INTERFACE txqueuelen 500'
ExecStart=/bin/bash -c 'ethtool -G $INTERFACE rx 256 tx 256 || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable low-latency-network.service
echo "✓ Persistence service created"
echo ""
((STEP++))

echo "[$STEP/$TOTAL] Validating configuration..."
ERRORS=0

# Check critical settings
if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbr" ]; then
    echo "✗ BBR not active"
    ((ERRORS++))
else
    echo "✓ BBR active"
fi

if [ "$(cat /sys/kernel/mm/transparent_hugepage/enabled)" != "[never]" ]; then
    echo "✗ THP not disabled"
    ((ERRORS++))
else
    echo "✓ THP disabled"
fi

QDISC=$(tc qdisc show dev $INTERFACE | grep "^qdisc fq")
if [ -z "$QDISC" ]; then
    echo "✗ FQ qdisc not active"
    ((ERRORS++))
else
    echo "✓ FQ qdisc active"
fi

echo ""
((STEP++))

echo "[$STEP/$TOTAL] Generating verification report..."
cat << 'EOF' > /root/low-latency-config-report.txt
Low-Latency Configuration Report
Generated: $(date)
================================

Network Configuration:
EOF

{
    echo ""
    echo "Interface: $INTERFACE"
    ip link show $INTERFACE
    echo ""
    echo "Qdisc:"
    tc qdisc show dev $INTERFACE
    echo ""
    echo "Ring Buffers:"
    ethtool -g $INTERFACE 2>/dev/null || echo "Not available"
    echo ""
    echo "Key Kernel Parameters:"
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.ipv4.tcp_ecn
    sysctl net.ipv4.tcp_fastopen
    sysctl net.core.rmem_max
    sysctl net.core.wmem_max
    echo ""
    echo "THP Status:"
    cat /sys/kernel/mm/transparent_hugepage/enabled
} >> /root/low-latency-config-report.txt

echo "✓ Report generated: /root/low-latency-config-report.txt"
echo ""

echo "======================================================="
echo "  Deployment Complete"
echo "======================================================="
echo ""
if [ $ERRORS -eq 0 ]; then
    echo "✓ All checks passed"
else
    echo "⚠ $ERRORS validation errors found"
    echo "  Review /root/low-latency-config-report.txt"
fi
echo ""
echo "IMPORTANT:"
echo "1. Review the configuration: cat /root/low-latency-config-report.txt"
echo "2. Update GRUB: grub2-mkconfig -o /boot/grub2/grub.cfg"
echo "3. Reboot system for all changes to take effect"
echo "4. After reboot, run validation: ./validate-configuration.sh"
echo ""
echo "Backup location: $BACKUP_DIR"
```

## Verification Checklist

### Post-Deployment Validation

```bash
#!/bin/bash
# validate-configuration.sh
# Comprehensive validation of low-latency configuration

# Detect default network interface dynamically
if [ -z "$1" ]; then
    INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "Error: Could not determine default network interface"
        echo "Usage: $0 [interface_name]"
        exit 1
    fi
else
    INTERFACE="$1"
fi

echo "===== Low-Latency Configuration Validation ====="
echo ""

PASS=0
FAIL=0
WARN=0

check() {
    local name="$1"
    local command="$2"
    local expected="$3"
    
    result=$(eval "$command" 2>/dev/null)
    
    if [ "$result" = "$expected" ]; then
        echo "✓ $name"
        ((PASS++))
        return 0
    else
        echo "✗ $name (Expected: $expected, Got: $result)"
        ((FAIL++))
        return 1
    fi
}

warn_check() {
    local name="$1"
    local command="$2"
    local expected="$3"
    
    result=$(eval "$command" 2>/dev/null)
    
    if [ "$result" = "$expected" ]; then
        echo "✓ $name"
        ((PASS++))
    else
        echo "⚠ $name (Expected: $expected, Got: $result)"
        ((WARN++))
    fi
}

echo "[Network Stack]"
check "BBR enabled" "sysctl -n net.ipv4.tcp_congestion_control" "bbr"
check "ECN enabled" "sysctl -n net.ipv4.tcp_ecn" "1"
check "TCP Fast Open" "sysctl -n net.ipv4.tcp_fastopen" "3"
check "Slow start after idle disabled" "sysctl -n net.ipv4.tcp_slow_start_after_idle" "0"
echo ""

echo "[Interface Configuration]"
check "MTU" "ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+'" "1500"
check "TXQueueLen" "ip link show $INTERFACE | grep -oP 'qlen \K[0-9]+'" "500"
check "FQ qdisc" "tc qdisc show dev $INTERFACE | grep -c '^qdisc fq'" "1"
echo ""

echo "[System Settings]"
check "THP disabled" "cat /sys/kernel/mm/transparent_hugepage/enabled | grep -o '\[never\]'" "[never]"
warn_check "CPU governor" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" "performance"
echo ""

echo "[Buffer Sizes]"
RMEM_MAX=$(sysctl -n net.core.rmem_max)
if [ $RMEM_MAX -ge 16777216 ]; then
    echo "✓ rmem_max adequate ($RMEM_MAX)"
    ((PASS++))
else
    echo "✗ rmem_max too small ($RMEM_MAX)"
    ((FAIL++))
fi

WMEM_MAX=$(sysctl -n net.core.wmem_max)
if [ $WMEM_MAX -ge 16777216 ]; then
    echo "✓ wmem_max adequate ($WMEM_MAX)"
    ((PASS++))
else
    echo "✗ wmem_max too small ($WMEM_MAX)"
    ((FAIL++))
fi
echo ""

echo "===== Validation Summary ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Warnings: $WARN"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✓ Configuration validated successfully"
    exit 0
else
    echo "✗ Configuration has $FAIL failures"
    echo "Review and fix issues before deploying to production"
    exit 1
fi
```

## Key Takeaways

1. **Holistic Configuration**: Minimizing latency requires tuning at every network layer
   - Network interface, kernel, CPU, and system resource limits
   - A single misconfigured parameter can undermine all other optimizations
   - All layers must work together coherently

2. **Congestion Control and Queueing**: Choose algorithms matching deployment scenario
   - BBR congestion control algorithm handles variable network conditions
   - fq (fair queue) discipline with packet pacing reduces burst-induced latency
   - ECN (Explicit Congestion Notification) enables faster adaptation to congestion
   - Appropriate for both datacenter and Internet deployments

3. **Buffer Sizing Matched to Message Patterns**: Reduce unnecessary queuing
   - For 1-2KB messages: 256KB socket buffers across both deployment scenarios
   - Datacenter (1-5ms RTT): Option to use 64KB for minimal latency
   - Internet (50-200ms RTT): 256-4MB for resilience to packet loss and jitter
   - TX queue length 500 reduces device-level buffering (≈6ms at 1Gbps)
   - NIC ring buffers 256 prevents hardware buffer overflow

4. **Eliminate Latency Variability**: Remove unpredictable system behaviors
   - Disable Transparent Huge Pages (unpredictable memory allocation)
   - Disable slow start after idle (prevent connection restart delays)
   - Disable interrupt coalescing (process packets immediately)
   - Configure CPU for consistent performance (prevent deep sleep states)

5. **Application Coordination**: Applications must configure sockets appropriately
   - Disable Nagle's algorithm (TCP_NODELAY) for immediate transmission
   - Set buffer sizes matching message patterns and RTT
   - Enable quick ACK transmission (TCP_QUICKACK) for responsive feedback
   - Set connection timeout appropriately (TCP_USER_TIMEOUT)

6. **Measurement and Validation**: Verify configuration effectiveness
   - Establish performance baseline before applying changes
   - Validate each setting independently
   - Test behavior under realistic load patterns
   - Monitor continuously in production

7. **Configuration Persistence**: Ensure settings survive system reboot
   - Systemd services for interface settings (qdisc, ring buffers, TX queue)
   - sysctl.conf for kernel parameters
   - GRUB configuration for boot-time settings
   - Document all changes with rationale

## What's Next

With the complete system profile established, the next documents cover diagnostics and ongoing operations:

- **[Diagnostics and Troubleshooting](09-diagnostics-and-troubleshooting.md)**: Common inconsistency patterns and troubleshooting procedures
- **[Monitoring and Maintenance](10-monitoring-maintenance.md)**: Continuous performance monitoring and tuning adjustments
- **[Practical Shell Scripts and Recipes](11-shell-scripts-recipes.md)**: Production-ready automation and reference scripts

---

**Previous**: [RTT-Driven Buffer Sizing and BDP Calculations](07-rtt-buffer-sizing.md)
**Next**: [Complete Validation Procedure](09-validation-procedure.md)
