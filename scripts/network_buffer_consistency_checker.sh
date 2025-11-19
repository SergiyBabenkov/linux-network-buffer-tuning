#!/bin/bash
#
# network_buffer_consistency_checker.sh
# Comprehensive consistency validation for Linux network buffers
#
# Usage: sudo ./network_buffer_consistency_checker.sh [--detailed] [--fix]
#


# Step 1: Layer Relationship Validator
check_layer_relationships() {
    echo "=== STEP 1: Validating Layer Relationships ==="
    
    # Get all values
    local TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')
    local PAGE_SIZE=$(getconf PAGESIZE)
    
    # Layer 1: Global TCP Memory
    local TCP_MEM=$(sysctl -n net.ipv4.tcp_mem)
    read TCP_MEM_LOW TCP_MEM_PRES TCP_MEM_HIGH <<< "$TCP_MEM"
    local TCP_MEM_HIGH_BYTES=$((TCP_MEM_HIGH * PAGE_SIZE))
    
    # Layer 2: Core limits
    local RMEM_MAX=$(sysctl -n net.core.rmem_max)
    local WMEM_MAX=$(sysctl -n net.core.wmem_max)
    
    # Layer 3: TCP specific
    local TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)
    read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
    local TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem)
    read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"
    
    # CHECK 1.1: tcp_mem[high] should be reasonable vs total RAM
    local TCP_MEM_PERCENT=$((TCP_MEM_HIGH_BYTES * 100 / TOTAL_RAM))
    echo "Check 1.1: Global TCP Memory vs RAM"
    echo "  TCP memory limit: $(numfmt --to=iec $TCP_MEM_HIGH_BYTES) (${TCP_MEM_PERCENT}% of RAM)"
    
    if (( TCP_MEM_PERCENT > 50 )); then
        echo "  ❌ FAIL: TCP can use >50% of RAM - may starve other processes"
        echo "  Recommendation: Set to 10-25% of RAM"
        return 1
    elif (( TCP_MEM_PERCENT < 5 )); then
        echo "  ⚠️  WARN: TCP limited to <5% of RAM - may be too restrictive"
    else
        echo "  ✅ PASS: TCP memory allocation is reasonable"
    fi
    
    # CHECK 1.2: rmem_max should be <= tcp_mem[high]
    echo ""
    echo "Check 1.2: Core rmem_max vs Global TCP Memory"
    echo "  rmem_max: $(numfmt --to=iec $RMEM_MAX)"
    echo "  tcp_mem[high]: $(numfmt --to=iec $TCP_MEM_HIGH_BYTES)"
    
    if (( RMEM_MAX > TCP_MEM_HIGH_BYTES )); then
        echo "  ⚠️  WARN: Single socket can consume more than total TCP limit"
        echo "  This is OK if you have few connections, problematic for many connections"
    else
        echo "  ✅ PASS: Single socket limit fits within global limit"
    fi
    
    # CHECK 1.3: CRITICAL - tcp_rmem[max] vs rmem_max
    echo ""
    echo "Check 1.3: TCP auto-tuning max vs Core limit (CRITICAL)"
    echo "  tcp_rmem[max]: $(numfmt --to=iec $TCP_RMEM_MAX)"
    echo "  rmem_max:      $(numfmt --to=iec $RMEM_MAX)"
    
    if (( TCP_RMEM_MAX > RMEM_MAX )); then
        echo "  ❌ CRITICAL FAIL: tcp_rmem[max] > rmem_max"
        echo "  IMPACT: TCP auto-tuning CANNOT reach tcp_rmem[max]!"
        echo "  ACTUAL LIMIT: $RMEM_MAX bytes (not $TCP_RMEM_MAX)"
        echo "  FIX: sysctl -w net.core.rmem_max=$TCP_RMEM_MAX"
        return 1
    else
        local HEADROOM=$((RMEM_MAX - TCP_RMEM_MAX))
        echo "  ✅ PASS: Auto-tuning can reach intended maximum"
        echo "  Headroom: $(numfmt --to=iec $HEADROOM)"
    fi
    
    # CHECK 1.4: tcp_wmem[max] vs wmem_max
    echo ""
    echo "Check 1.4: TCP send buffer max vs Core limit (CRITICAL)"
    echo "  tcp_wmem[max]: $(numfmt --to=iec $TCP_WMEM_MAX)"
    echo "  wmem_max:      $(numfmt --to=iec $WMEM_MAX)"
    
    if (( TCP_WMEM_MAX > WMEM_MAX )); then
        echo "  ❌ CRITICAL FAIL: tcp_wmem[max] > wmem_max"
        echo "  FIX: sysctl -w net.core.wmem_max=$TCP_WMEM_MAX"
        return 1
    else
        echo "  ✅ PASS: Send buffer auto-tuning properly configured"
    fi
    
    return 0
}

check_feature_dependencies() {
    echo ""
    echo "=== STEP 2: Validating Feature Dependencies ==="
    
    local TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)
    read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
    
    local TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem)
    read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"
    
    # CHECK 2.1: Window scaling required for buffers > 64KB
    echo "Check 2.1: TCP Window Scaling"
    local WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)
    
    if (( TCP_RMEM_MAX > 65536 || TCP_WMEM_MAX > 65536 )); then
        echo "  Buffer size: >64KB detected"
        echo "  Window scaling: $WINDOW_SCALING"
        
        if [[ $WINDOW_SCALING -ne 1 ]]; then
            echo "  ❌ CRITICAL FAIL: Window scaling DISABLED!"
            echo "  IMPACT: Buffers >64KB are USELESS without window scaling"
            echo "  EXPLANATION:"
            echo "    - TCP window field is 16 bits = max 65,535 bytes"
            echo "    - Window scaling allows multiplying this by up to 2^14"
            echo "    - Without it, effective buffer is capped at 64KB"
            echo "  FIX: sysctl -w net.ipv4.tcp_window_scaling=1"
            return 1
        else
            echo "  ✅ PASS: Window scaling enabled for large buffers"
        fi
    else
        echo "  ℹ️  INFO: Buffers ≤64KB, window scaling not required"
        echo "  Current setting: $WINDOW_SCALING"
    fi
    
    # CHECK 2.2: Auto-tuning enabled
    echo ""
    echo "Check 2.2: TCP Auto-tuning"
    local MODERATE_RCVBUF=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)
    echo "  tcp_moderate_rcvbuf: $MODERATE_RCVBUF"
    
    if [[ $MODERATE_RCVBUF -ne 1 ]]; then
        echo "  ❌ FAIL: TCP receive buffer auto-tuning DISABLED"
        echo "  IMPACT: Buffers won't grow beyond tcp_rmem[default]"
        echo "  You configured tcp_rmem[max]=$TCP_RMEM_MAX but it won't be used!"
        echo "  FIX: sysctl -w net.ipv4.tcp_moderate_rcvbuf=1"
        return 1
    else
        echo "  ✅ PASS: Auto-tuning enabled, buffers will grow dynamically"
    fi
    
    # CHECK 2.3: TCP timestamps (affects RTT measurement for auto-tuning)
    echo ""
    echo "Check 2.3: TCP Timestamps (for RTT measurement)"
    local TCP_TIMESTAMPS=$(sysctl -n net.ipv4.tcp_timestamps)
    echo "  tcp_timestamps: $TCP_TIMESTAMPS"
    
    if [[ $TCP_TIMESTAMPS -eq 1 ]]; then
        echo "  ✅ ENABLED: Better RTT measurement, better auto-tuning"
        echo "  Trade-off: +12 bytes per packet overhead"
    else
        echo "  ⚠️  DISABLED: Auto-tuning uses fallback RTT estimation"
        echo "  May be OK for low-latency workloads"
    fi
    
    return 0
}

check_connection_capacity() {
    echo ""
    echo "=== STEP 3: Connection Capacity Analysis ==="
    
    local PAGE_SIZE=$(getconf PAGESIZE)
    local TCP_MEM=$(sysctl -n net.ipv4.tcp_mem)
    read TCP_MEM_LOW TCP_MEM_PRES TCP_MEM_HIGH <<< "$TCP_MEM"
    local TCP_MEM_HIGH_BYTES=$((TCP_MEM_HIGH * PAGE_SIZE))
    
    local TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)
    read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
    
    local TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem)
    read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"
    
    # Calculate different scenarios
    echo "Theoretical Connection Limits:"
    echo ""
    
    # Scenario 1: All connections at default buffer size
    local AVG_BUFFER_DEFAULT=$((TCP_RMEM_DEF + TCP_WMEM_DEF))
    local CONNECTIONS_DEFAULT=$((TCP_MEM_HIGH_BYTES / AVG_BUFFER_DEFAULT))
    echo "  Scenario 1: All connections at DEFAULT buffer size"
    echo "    Average per connection: $(numfmt --to=iec $AVG_BUFFER_DEFAULT)"
    echo "    Maximum connections: $(printf "%'d" $CONNECTIONS_DEFAULT)"
    
    # Scenario 2: All connections at maximum buffer size
    local AVG_BUFFER_MAX=$((TCP_RMEM_MAX + TCP_WMEM_MAX))
    local CONNECTIONS_MAX=$((TCP_MEM_HIGH_BYTES / AVG_BUFFER_MAX))
    echo ""
    echo "  Scenario 2: All connections at MAXIMUM buffer size"
    echo "    Average per connection: $(numfmt --to=iec $AVG_BUFFER_MAX)"
    echo "    Maximum connections: $(printf "%'d" $CONNECTIONS_MAX)"
    
    # Scenario 3: Realistic (50% at default, 50% at 2x default)
    local AVG_BUFFER_REALISTIC=$((TCP_RMEM_DEF + TCP_WMEM_DEF + (TCP_RMEM_DEF + TCP_WMEM_DEF) / 2))
    local CONNECTIONS_REALISTIC=$((TCP_MEM_HIGH_BYTES / AVG_BUFFER_REALISTIC))
    echo ""
    echo "  Scenario 3: REALISTIC mix (auto-tuning active)"
    echo "    Average per connection: $(numfmt --to=iec $AVG_BUFFER_REALISTIC)"
    echo "    Estimated connections: $(printf "%'d" $CONNECTIONS_REALISTIC)"
    
    # Check current usage
    echo ""
    echo "Current System State:"
    local CURRENT_CONNS=$(ss -tan | grep ESTAB | wc -l)
    echo "  Active TCP connections: $(printf "%'d" $CURRENT_CONNS)"
    
    if command -v numfmt &>/dev/null; then
        local TCP_MEM_USED=$(awk '/^TCP:/{print $NF}' /proc/net/sockstat 2>/dev/null || echo 0)
        if [[ $TCP_MEM_USED -gt 0 ]]; then
            local TCP_MEM_USED_BYTES=$((TCP_MEM_USED * PAGE_SIZE))
            local USAGE_PERCENT=$((TCP_MEM_USED_BYTES * 100 / TCP_MEM_HIGH_BYTES))
            echo "  TCP memory used: $(numfmt --to=iec $TCP_MEM_USED_BYTES) (${USAGE_PERCENT}%)"
            
            if (( CURRENT_CONNS > 0 )); then
                local AVG_PER_CONN=$((TCP_MEM_USED_BYTES / CURRENT_CONNS))
                echo "  Average per connection: $(numfmt --to=iec $AVG_PER_CONN)"
            fi
            
            if (( USAGE_PERCENT > 80 )); then
                echo "  ❌ WARNING: TCP memory usage >80% - risk of pressure!"
            elif (( USAGE_PERCENT > 50 )); then
                echo "  ⚠️  CAUTION: TCP memory usage >50%"
            else
                echo "  ✅ HEALTHY: TCP memory usage is good"
            fi
        fi
    fi
    
    # Recommendations
    echo ""
    echo "Recommendations:"
    if (( CONNECTIONS_MAX < 1000 )); then
        echo "  ⚠️  WARNING: System can only support $(printf "%'d" $CONNECTIONS_MAX) connections at max buffers"
        echo "  Consider: Reduce tcp_rmem[max] and tcp_wmem[max], or increase tcp_mem"
    fi
    
    return 0
}

check_queue_consistency() {
    echo ""
    echo "=== STEP 4: Queue Configuration Consistency ==="
    
    local CPU_CORES=$(nproc)
    local TOTAL_RAM_GB=$(($(free -b | awk '/^Mem:/{print $2}') / 1073741824))
    
    # Application-level queues
    echo "Check 4.1: Application Listen Queues"
    local SOMAXCONN=$(sysctl -n net.core.somaxconn)
    echo "  somaxconn (listen backlog limit): $SOMAXCONN"
    
    # Calculate recommended based on system size
    local RECOMMENDED_SOMAXCONN=$((512 * TOTAL_RAM_GB))
    if (( RECOMMENDED_SOMAXCONN < 1024 )); then
        RECOMMENDED_SOMAXCONN=1024
    fi
    if (( RECOMMENDED_SOMAXCONN > 65535 )); then
        RECOMMENDED_SOMAXCONN=65535
    fi
    
    echo "  Recommended for ${TOTAL_RAM_GB}GB RAM: $RECOMMENDED_SOMAXCONN"
    
    if (( SOMAXCONN < RECOMMENDED_SOMAXCONN )); then
        echo "  ⚠️  LOW: May cause connection drops under load"
        echo "  FIX: sysctl -w net.core.somaxconn=$RECOMMENDED_SOMAXCONN"
    else
        echo "  ✅ ADEQUATE"
    fi
    
    # SYN queue
    echo ""
    echo "Check 4.2: SYN Queue (Half-Open Connections)"
    local TCP_MAX_SYN_BACKLOG=$(sysctl -n net.ipv4.tcp_max_syn_backlog)
    echo "  tcp_max_syn_backlog: $TCP_MAX_SYN_BACKLOG"
    
    local RECOMMENDED_SYN=$((RECOMMENDED_SOMAXCONN * 2))
    echo "  Recommended: $RECOMMENDED_SYN (2x somaxconn)"
    
    if (( TCP_MAX_SYN_BACKLOG < RECOMMENDED_SYN )); then
        echo "  ⚠️  LOW: Vulnerable to SYN floods, may drop connections"
        echo "  FIX: sysctl -w net.ipv4.tcp_max_syn_backlog=$RECOMMENDED_SYN"
    else
        echo "  ✅ ADEQUATE"
    fi
    
    # Network device queues
    echo ""
    echo "Check 4.3: Network Device Input Queue"
    local NETDEV_MAX_BACKLOG=$(sysctl -n net.core.netdev_max_backlog)
    echo "  netdev_max_backlog (per-CPU): $NETDEV_MAX_BACKLOG"
    
    # Calculate based on link speed expectations
    # 10Gbps can deliver ~1.4M packets/sec at 1000 bytes
    # With 8 CPUs, that's ~175K packets/sec per CPU
    # At 1ms burst, need queue for 175 packets
    # Recommend 3-5x for safety
    
    local RECOMMENDED_NETDEV=$((1000 * CPU_CORES))
    if (( RECOMMENDED_NETDEV < 1000 )); then
        RECOMMENDED_NETDEV=1000
    fi
    
    echo "  Recommended for ${CPU_CORES} CPUs: $RECOMMENDED_NETDEV"
    
    if (( NETDEV_MAX_BACKLOG < RECOMMENDED_NETDEV )); then
        echo "  ⚠️  LOW: May drop packets under bursts"
        echo "  FIX: sysctl -w net.core.netdev_max_backlog=$RECOMMENDED_NETDEV"
    else
        echo "  ✅ ADEQUATE"
    fi
    
    # Check interface TX queues
    echo ""
    echo "Check 4.4: Interface Transmit Queues"
    
    local INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -3)
    for iface in $INTERFACES; do
        local TXQUEUELEN=$(ip link show $iface | grep -oP 'qlen \K\d+' 2>/dev/null || echo "N/A")
        echo "  $iface txqueuelen: $TXQUEUELEN"
        
        if [[ $TXQUEUELEN != "N/A" ]]; then
            # Get interface speed
            local SPEED=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "unknown")
            
            if [[ $SPEED != "unknown" && $SPEED != "-1" ]]; then
                # Recommend queue length based on speed
                # 1Gbps = 1000, 10Gbps = 10000
                local RECOMMENDED_TXQ=$((SPEED))
                if (( RECOMMENDED_TXQ < 1000 )); then
                    RECOMMENDED_TXQ=1000
                fi
                if (( RECOMMENDED_TXQ > 10000 )); then
                    RECOMMENDED_TXQ=10000
                fi
                
                echo "    Interface speed: ${SPEED}Mbps"
                echo "    Recommended: $RECOMMENDED_TXQ"
                
                if (( TXQUEUELEN < RECOMMENDED_TXQ )); then
                    echo "    ⚠️  LOW for ${SPEED}Mbps link"
                    echo "    FIX: ip link set $iface txqueuelen $RECOMMENDED_TXQ"
                else
                    echo "    ✅ ADEQUATE"
                fi
            fi
        fi
    done
    
    return 0
}

check_runtime_state() {
    echo ""
    echo "=== STEP 5: Runtime State Verification ==="
    
    # Check if connections are hitting limits
    echo "Check 5.1: Connection State Analysis"
    
    if command -v ss &>/dev/null; then
        echo "  Analyzing active connections..."
        
        # Sample a few connections to see actual buffer usage
        local SAMPLE_OUTPUT=$(ss -tm state established | grep -A1 "skmem:" | head -20)
        
        if [[ -n $SAMPLE_OUTPUT ]]; then
            echo ""
            echo "  Sample Connection Buffer Usage:"
            echo "  (Format: r=actual_rmem, rb=rmem_limit, t=actual_wmem, tb=wmem_limit)"
            echo ""
            echo "$SAMPLE_OUTPUT" | grep "skmem:" | head -5
            
            # Parse and analyze
            local RMEM_ACTUAL=$(echo "$SAMPLE_OUTPUT" | grep -oP 'r\K\d+' | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count)}')
            local RMEM_LIMIT=$(echo "$SAMPLE_OUTPUT" | grep -oP 'rb\K\d+' | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count)}')
            
            if [[ -n $RMEM_ACTUAL && -n $RMEM_LIMIT ]]; then
                echo ""
                echo "  Average from sample:"
                echo "    Actual receive buffer in use: $(numfmt --to=iec $RMEM_ACTUAL 2>/dev/null || echo $RMEM_ACTUAL)"
                echo "    Receive buffer limit: $(numfmt --to=iec $RMEM_LIMIT 2>/dev/null || echo $RMEM_LIMIT)"
                
                local USAGE_PERCENT=$((RMEM_ACTUAL * 100 / RMEM_LIMIT))
                echo "    Buffer utilization: ${USAGE_PERCENT}%"
                
                if (( USAGE_PERCENT > 90 )); then
                    echo "    ⚠️  HIGH: Connections are using >90% of buffer - may need larger buffers"
                elif (( USAGE_PERCENT < 10 )); then
                    echo "    ℹ️  LOW: Buffers may be oversized for this workload"
                else
                    echo "    ✅ HEALTHY: Buffer usage is reasonable"
                fi
            fi
        else
            echo "  ℹ️  No established connections found to analyze"
        fi
    fi
    
    # Check for packet drops
    echo ""
    echo "Check 5.2: Packet Drop Analysis"
    
    if command -v nstat &>/dev/null; then
        echo "  TCP packet statistics (since last check):"
        
        # Reset and collect over 1 second
        nstat -z > /dev/null 2>&1
        sleep 1
        local NSTAT_OUTPUT=$(nstat)
        
        # Look for drops and errors
        local TCP_DROPS=$(echo "$NSTAT_OUTPUT" | grep -i "drop" || echo "None")
        local TCP_ERRORS=$(echo "$NSTAT_OUTPUT" | grep -i "error" || echo "None")
        
        echo "  Drops:"
        echo "$TCP_DROPS" | sed 's/^/    /'
        
        if echo "$TCP_DROPS" | grep -q "None"; then
            echo "    ✅ No drops detected"
        else
            echo "    ⚠️  Drops detected - investigate buffer/queue sizes"
        fi
    fi
    
    # Check interface drops
    echo ""
    echo "Check 5.3: Interface Drop Statistics"
    
    local INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -3)
    for iface in $INTERFACES; do
        echo "  Interface: $iface"
        local STATS=$(ip -s link show $iface 2>/dev/null)
        
        local RX_DROPPED=$(echo "$STATS" | grep -A1 "RX:" | tail -1 | awk '{print $4}')
        local TX_DROPPED=$(echo "$STATS" | grep -A1 "TX:" | tail -1 | awk '{print $4}')
        
        echo "    RX dropped: $RX_DROPPED"
        echo "    TX dropped: $TX_DROPPED"
        
        if [[ $RX_DROPPED -gt 0 || $TX_DROPPED -gt 0 ]]; then
            echo "    ⚠️  Drops detected - check netdev_max_backlog and ring buffers"
        else
            echo "    ✅ No drops"
        fi
    done
    
    return 0
}

#!/bin/bash
#
# network_buffer_consistency_checker.sh
# Comprehensive consistency validation for Linux network buffers
#
# Usage: sudo ./network_buffer_consistency_checker.sh [--detailed] [--fix]
#

set -euo pipefail

# Configuration
DETAILED=false
AUTO_FIX=false
REPORT_FILE="/tmp/network_consistency_$(date +%Y%m%d_%H%M%S).txt"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --detailed)
            DETAILED=true
            ;;
        --fix)
            AUTO_FIX=true
            ;;
        --help)
            cat << EOF
Network Buffer Consistency Checker

Usage: $0 [OPTIONS]

Options:
    --detailed    Show detailed explanations
    --fix         Automatically fix issues (requires root)
    --help        Show this help message

This script performs a comprehensive consistency check of:
  - Buffer size relationships (tcp_rmem vs rmem_max, etc.)
  - Feature dependencies (window scaling, auto-tuning)
  - Connection capacity calculations
  - Queue configuration
  - Runtime state validation

Output is saved to /tmp/network_consistency_*.txt
EOF
            exit 0
            ;;
    esac
done

# Check root for some operations
if [[ $AUTO_FIX == true && $EUID -ne 0 ]]; then
    echo "ERROR: --fix requires root privileges"
    exit 1
fi

# Initialize report
{
    echo "=========================================="
    echo "Network Buffer Consistency Check Report"
    echo "=========================================="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo ""
} | tee "$REPORT_FILE"

# Track overall status
OVERALL_STATUS=0

# Helper function for formatted output
report() {
    echo "$@" | tee -a "$REPORT_FILE"
}

# Include all check functions here (from Step 1-5 above)
# [Insert the functions: check_layer_relationships, check_feature_dependencies, 
#  check_connection_capacity, check_queue_consistency, check_runtime_state]

# Main execution
main() {
    report "Starting comprehensive consistency check..."
    report ""
    
    # Run all checks
    check_layer_relationships || OVERALL_STATUS=1
    check_feature_dependencies || OVERALL_STATUS=1
    check_connection_capacity || OVERALL_STATUS=1
    check_queue_consistency || OVERALL_STATUS=1
    check_runtime_state || OVERALL_STATUS=1
    
    # Summary
    report ""
    report "=========================================="
    report "SUMMARY"
    report "=========================================="
    
    if [[ $OVERALL_STATUS -eq 0 ]]; then
        report "✅ ALL CHECKS PASSED"
        report "Your network buffer configuration is consistent and properly tuned."
    else
        report "❌ ISSUES DETECTED"
        report "Review the detailed output above for specific problems and fixes."
    fi
    
    report ""
    report "Full report saved to: $REPORT_FILE"
    
    return $OVERALL_STATUS
}

# Run main
main
exit $?
