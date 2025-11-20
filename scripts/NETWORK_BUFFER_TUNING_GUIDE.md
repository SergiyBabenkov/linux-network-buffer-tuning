# Network Buffer Tuning Guide - Comprehensive Analysis Script

## Overview

`network_buffer_tuning_guide.sh` is a self-descriptive, comprehensive analysis script that diagnoses network buffer configuration issues and provides actionable remediation guidance for RHEL/OEL 8 systems.

The script analyzes the complete buffer hierarchy, identifies inconsistencies, detects pain points, and generates specific tuning recommendations for your workload and deployment scenario.

## Key Features

### 1. **Comprehensive Analysis**
- Complete buffer hierarchy consistency checking
- TCP memory pressure analysis
- Active socket buffer inspection
- Interface configuration validation
- Pain point and hot spot identification

### 2. **Dual Use Case Support**
```
MESSAGE DELIVERY SYSTEMS (1-2KB messages)
├─ Optimize for: Low latency, minimal packet loss
├─ Focus: Fast delivery of small messages
└─ Priority: Latency < Throughput

FILE TRANSFER SYSTEMS (MB-GB files)
├─ Optimize for: High throughput, efficient buffer usage
├─ Focus: Maximum bandwidth utilization
└─ Priority: Throughput > Latency
```

### 3. **Dual Deployment Architecture Support**
```
BACKEND COMPONENTS (Datacenter)
├─ RTT: 1-5ms (low, stable)
├─ Conditions: Stable, predictable
└─ Buffer Strategy: Minimal buffers

CUSTOMER-FACING COMPONENTS (Internet)
├─ RTT: 50-200ms (high, variable)
├─ Conditions: Jitter, packet loss
└─ Buffer Strategy: Larger buffers for resilience
```

### 4. **Four Tuning Profiles**

The script includes pre-configured optimal profiles for each combination:

#### Message Delivery - Backend (Datacenter)
- **Use Case:** Internal service-to-service communication
- **RTT:** 1-5ms
- **Message Size:** 1-2KB
- **Focus:** Absolute minimum latency
- **Buffer Sizes:** 32-128KB

#### Message Delivery - Internet (Customer-Facing)
- **Use Case:** External APIs, customer endpoints
- **RTT:** 50-200ms
- **Message Size:** 1-2KB
- **Focus:** Reliable delivery with resilience
- **Buffer Sizes:** 256KB-4MB

#### File Transfer - Backend (Datacenter)
- **Use Case:** High-speed internal file transfers
- **RTT:** 1-5ms
- **File Size:** MB to GB
- **Focus:** High throughput, minimal variance
- **Buffer Sizes:** 256KB-1MB

#### File Transfer - Internet (Cross-Region)
- **Use Case:** WAN file transfers between regions
- **RTT:** 50-200ms
- **File Size:** MB to GB
- **Focus:** Maximum throughput over long distances
- **Buffer Sizes:** 4-16MB

## Installation

```bash
# The script is provided in the scripts directory
sudo cp network_buffer_tuning_guide.sh /opt/scripts/
sudo chmod +x /opt/scripts/network_buffer_tuning_guide.sh
```

## Usage

### 1. View Current Configuration Analysis

```bash
sudo ./network_buffer_tuning_guide.sh
```

This shows:
- Current buffer configuration snapshot
- Buffer hierarchy consistency checks
- Memory pressure analysis
- Active socket buffer usage
- Pain points and hot spots requiring attention
- Available tuning profiles

### 2. Compare Against Specific Profile

```bash
# Message delivery on the Internet
sudo ./network_buffer_tuning_guide.sh --profile message-delivery-internet

# File transfer within datacenter
sudo ./network_buffer_tuning_guide.sh --profile file-transfer-backend
```

This shows:
- Detailed comparison of current vs recommended settings
- Specific remediation commands
- Copy-paste ready configuration blocks

### 3. Apply Profile Settings

```bash
# Apply configuration (creates automatic backup)
sudo ./network_buffer_tuning_guide.sh --apply message-delivery-internet
```

**Important:** The `--apply` flag will:
1. Create automatic backup of current configuration
2. Apply all recommended settings
3. Verify changes were applied successfully
4. Show rollback command if needed

### 4. Get Help

```bash
sudo ./network_buffer_tuning_guide.sh --help
```

## What the Script Analyzes

### Section 1: Dynamic Interface Detection
- Automatically detects your default network interface
- Works on any system (eth0, ens0, enp0s3, etc.)
- No hardcoded assumptions

### Section 2: Current Configuration Snapshot
Displays:
- Network interface properties (MTU, TX queue length)
- Congestion control algorithm
- All buffer limit parameters

### Section 3: Buffer Hierarchy Consistency
Checks:
- `tcp_rmem[2]` ≤ `rmem_max` (auto-tuning capability)
- `tcp_wmem[2]` ≤ `wmem_max` (auto-tuning capability)
- Window scaling enabled for large buffers
- Auto-tuning status
- Minimum and default buffer sanity

**Why This Matters:**
If `tcp_rmem[2]` > `rmem_max`, the kernel auto-tuning is capped and cannot allocate the full configured maximum. This silently limits performance.

### Section 4: TCP Memory Pressure Analysis
Analyzes:
- Current memory usage relative to thresholds
- Percentage of low/pressure/high limits
- Number of active connections
- Number of orphaned sockets
- Average buffer size per connection
- Memory pressure status (healthy/pressure/critical)

**Why This Matters:**
When approaching pressure threshold, TCP starts rejecting allocations. This causes connection failures and application errors.

### Section 5: Active Socket Buffer Inspection
Shows:
- Sample of current connections and their buffer usage
- Format interpretation (r/rb/t/tb meanings)
- Detection of buffer saturation
- Connections with >80% buffer utilization

**Why This Matters:**
Saturated buffers indicate imminent packet loss. High saturation is a pain point requiring immediate attention.

### Section 6: Pain Points and Hot Spots
Identifies critical issues requiring attention:

| Issue | Impact | Action |
|-------|--------|--------|
| Hierarchy inconsistency | Auto-tuning limited | Fix rmem_max/wmem_max |
| Small buffers + high RTT | Poor throughput | Increase buffer sizes |
| Large buffers + low RTT | Unnecessary latency | Decrease buffer sizes |
| Memory pressure | Connection failures | Reduce allocations |
| Window scaling disabled | 64KB TCP limit | Enable TCP window scaling |
| Small defaults | Poor initial performance | Increase default sizes |
| Unusual MTU | Configuration mismatch | Verify network settings |
| CUBIC congestion control | Latency variance | Consider BBR instead |

### Section 7: Profile Comparison
Shows:
- Current value vs recommended value for each parameter
- Highlights what needs to change
- Explains the rationale for each profile

### Section 8: Remediation Commands
Provides three options:
1. **Temporary (lost on reboot)** - Quick testing
2. **Persistent (recommended)** - System configuration file
3. **With automatic backup** - Safe deployment

## Understanding the Output

### Color Coding

```
✓  GREEN   - Configuration is correct/optimal
✗  RED     - Critical issue requiring immediate attention
⚠  YELLOW  - Warning, attention recommended
ℹ  BLUE    - Informational message
```

### Pain Point Priority

**CRITICAL (Act Now)**
- Buffer hierarchy inconsistency
- Memory pressure exceeded
- Window scaling disabled with large buffers

**WARNING (Attention Recommended)**
- Buffer sizes mismatched for RTT
- Small default buffers
- Unusual network configuration

**INFO (Informational)**
- Congestion control algorithm choices
- Current memory usage levels

## Examples

### Example 1: Internet-Based Message Delivery Service

**Scenario:** Customer-facing API handling 1-2KB messages from global users

```bash
sudo ./network_buffer_tuning_guide.sh --profile message-delivery-internet
```

**Expected Issues:**
- Buffers might be too small (< 256KB)
- Memory limits might be inadequate
- Window scaling might be disabled

**Recommended Profile:**
- tcp_rmem: 4096 262144 4194304 (default 256KB, max 4MB)
- tcp_wmem: 4096 262144 4194304 (default 256KB, max 4MB)
- rmem_max: 4194304 (4MB)
- wmem_max: 4194304 (4MB)

### Example 2: Datacenter File Transfer

**Scenario:** Internal high-speed file transfer between servers in same datacenter

```bash
sudo ./network_buffer_tuning_guide.sh --profile file-transfer-backend
```

**Expected Issues:**
- Buffers might be oversized (> 1MB)
- Memory limits might be excessive
- Latency might be increased by large buffers

**Recommended Profile:**
- tcp_rmem: 4096 262144 1048576 (default 256KB, max 1MB)
- tcp_wmem: 4096 262144 1048576 (default 256KB, max 1MB)
- rmem_max: 1048576 (1MB)
- wmem_max: 1048576 (1MB)

### Example 3: Cross-Region File Transfer

**Scenario:** WAN file transfer between data centers 100ms apart

```bash
sudo ./network_buffer_tuning_guide.sh --profile file-transfer-internet
```

**Expected Issues:**
- Buffers might be too small
- Memory limits inadequate for BDP
- Throughput might be limited

**Recommended Profile:**
- tcp_rmem: 4096 4194304 16777216 (default 4MB, max 16MB)
- tcp_wmem: 4096 4194304 16777216 (default 4MB, max 16MB)
- rmem_max: 16777216 (16MB)
- wmem_max: 16777216 (16MB)

**Reasoning:**
At 100ms RTT over 10Gbps: BDP = 10Gbps × 0.1s = 1.25GB
Practical buffers: 4-16MB for sustained transfers

## Pain Points Explained

### Pain Point: Buffer Hierarchy Inconsistency

**Symptom:**
```
✗ tcp_rmem[2] (8388608) exceeds rmem_max (4194304)
  → Auto-tuning will be LIMITED to 4194304
```

**Why It's a Problem:**
- You configured tcp_rmem[2] = 8MB
- You set rmem_max = 4MB
- The kernel can NEVER allocate > 4MB despite your configuration
- Applications wasting resources asking for 8MB when capped at 4MB

**Fix:**
Option A: Increase rmem_max to at least 8MB
Option B: Decrease tcp_rmem[2] to not exceed rmem_max

### Pain Point: Memory Pressure

**Symptom:**
```
⚠ WARNING: Memory pressure threshold exceeded
  TCP reducing allocations for new connections
```

**Why It's a Problem:**
- New connections get smaller buffer allocations
- Performance becomes unpredictable
- Some connections might fail
- Existing connections might stall

**Fix:**
1. Reduce tcp_mem high threshold
2. Reduce individual buffer sizes
3. Increase system RAM if available

### Pain Point: Window Scaling Disabled

**Symptom:**
```
✗ CRITICAL: Window scaling DISABLED but buffers > 64KB
  Large windows won't be used by TCP
```

**Why It's a Problem:**
- You allocated 256KB buffers
- Window scaling disabled limits TCP window to 64KB
- Only using 25% of allocated buffer
- Throughput capped at 64KB window × RTT

**Fix:**
```bash
sudo sysctl -w net.ipv4.tcp_window_scaling=1
```

### Pain Point: Small Default Buffers

**Symptom:**
```
⚠ WARNING: Small default buffers (< 32KB)
  New connections start with limited capacity
```

**Why It's a Problem:**
- New connections get very small buffers
- Auto-tuning must increase them gradually
- Initial performance is poor
- Latency spikes during ramp-up

**Fix:**
- Increase tcp_rmem[1] (default receive buffer)
- Increase tcp_wmem[1] (default send buffer)

## Buffer Sizing Formulas

### Bandwidth-Delay Product (BDP)

Used to calculate optimal buffer sizes:

```
BDP (bytes) = Bandwidth (bits/sec) × RTT (seconds) / 8

Example:
- 1 Gbps, 1ms RTT → 125,000 bytes = 122 KB
- 1 Gbps, 50ms RTT → 6,250,000 bytes = 6.25 MB
- 10 Gbps, 10ms RTT → 12,500,000 bytes = 12.5 MB
```

Recommended buffer = 0.5-1.0 × BDP for optimal throughput

### For Message Delivery

Buffers should be:
- At least message size (1-2KB)
- Typically 10-20× message size (10-40KB minimum)
- For Internet: 100-500× message size (100KB-1MB typical)

### For File Transfer

Buffers should match or exceed BDP:
- At 1ms RTT: 100KB-1MB
- At 10ms RTT: 1-10MB
- At 100ms RTT: 10-100MB

## Validation After Changes

After applying configuration changes:

```bash
# Quick consistency check
sudo ./quick_network_buffer_consistency_check.sh

# Comprehensive audit
sudo ./network_buffer_audit.sh

# Verify with this script
sudo ./network_buffer_tuning_guide.sh
```

All checks should pass (✓ marks).

## Rollback Instructions

If issues occur after applying configuration:

```bash
# The script creates automatic backups
# Restore from the generated backup file:
sudo sysctl -p /root/sysctl-backup-<timestamp>.conf

# Or restore all default values:
sudo sysctl -e < /etc/sysctl.conf
sudo systemctl restart network
```

## Performance Testing After Tuning

### For Message Delivery

```bash
# Test with small messages under load
sockperf ping-pong -i <server> -t 60 -m 1024

# Measure latency distribution
ping -c 1000 -s 1024 <target> | grep rtt
```

### For File Transfer

```bash
# Test throughput
iperf3 -c <server> -t 60 -P 4 -R

# Monitor during transfer
watch -n 1 'tc -s qdisc show dev eth0'
```

## Troubleshooting

### Script says "Permission denied"

```bash
sudo chmod +x network_buffer_tuning_guide.sh
sudo ./network_buffer_tuning_guide.sh
```

### Script can't detect interface

```bash
# Check your interfaces
ip link show

# Run with explicit interface
# (Currently auto-detects, no manual option)
# File an issue if needed
```

### Applied changes but no improvement

1. Run the script again to verify consistency
2. Check for pain points in analysis
3. Ensure you selected correct profile for your use case
4. Verify application is using optimal socket options
5. Check for other bottlenecks (CPU, disk I/O, network hardware)

### Rollback didn't work

```bash
# Force reset to defaults and reboot
sudo sh -c 'echo "1" > /proc/sys/net/ipv4/tcp_tw_reuse'
sudo systemctl restart networking
sudo reboot
```

## Related Documentation

- **08-low-latency-profile.md** - System-wide tuning procedures
- **07-rtt-buffer-sizing.md** - Buffer calculation methodology
- **CLAUDE.md** - Project guidelines and standards
- **11-shell-scripts-recipes.md** - Operational recipes

## Technical Details

### What This Script Does NOT Do

- Does not modify firewall rules
- Does not change MTU settings
- Does not tune application code
- Does not install packages
- Does not modify interface hardware settings

### What This Script DOES Do

- Analyzes current configuration
- Identifies inconsistencies and pain points
- Provides expert recommendations
- Generates safe remediation commands
- Creates automatic backups before changes
- Validates changes were applied correctly

## Support and Feedback

For issues or suggestions:
1. Check the analysis output for specific pain points
2. Verify you selected the correct profile for your use case
3. Review the remediation commands before applying
4. Test changes in non-production first
5. Refer to related documentation

## Script Structure

The script is organized into clearly labeled sections:

```
Section 1:  Dynamic Interface Detection
Section 2:  Profile Definitions
Section 3:  Utility Functions
Section 4:  Current Configuration Analysis
Section 5:  Consistency Checking
Section 6:  Memory Pressure Analysis
Section 7:  Socket Buffer Inspection
Section 8:  Pain Points Identification
Section 9:  Profile Comparison
Section 10: Remediation Commands
Section 11: Profile Descriptions
Section 12: Main Execution Flow
```

Each section is self-contained and well-commented for easy understanding and modification.

## Version Information

- Script Version: 1.0
- Compatible with: RHEL 8, Oracle Linux 8, CentOS 8
- Requires: bash 4.0+, sysctl, ss, ethtool, tc
- Tested on: RHEL 8.5+, OEL 8.5+
