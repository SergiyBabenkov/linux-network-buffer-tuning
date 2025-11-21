#!/bin/bash

################################################################################
#
# NETWORK BUFFER TUNING GUIDE - Comprehensive Analysis and Recommendations
#
# PURPOSE:
#   This script provides a detailed analysis of current network buffer
#   configurations, identifies inconsistencies and pain points, and offers
#   specific tuning recommendations for two distinct use cases and deployment
#   architectures.
#
# USE CASES SUPPORTED:
#   1. Message Delivery Systems (1-2KB messages)
#      - Minimize latency and packet loss
#      - Fast, small packet delivery
#
#   2. File Transfer Systems (MB-GB files)
#      - Maximize throughput
#      - Efficient bandwidth utilization
#
# DEPLOYMENT ARCHITECTURES SUPPORTED:
#   1. Backend Components (Datacenter)
#      - Low RTT (1-5ms)
#      - Stable conditions
#      - Small buffers for minimal latency
#
#   2. Customer-Facing Components (Internet)
#      - High RTT (50-200ms)
#      - Variable conditions, packet loss
#      - Larger buffers for resilience
#
# FEATURES:
#   - Analyzes socket memory configuration
#   - Detects inconsistencies in buffer hierarchy
#   - Identifies pain points and bottlenecks
#   - Compares against optimal profiles
#   - Provides actionable recommendations
#   - Shows before/after comparison
#   - Generates remediation commands
#
# USAGE:
#   sudo ./network_buffer_tuning_guide.sh
#   sudo ./network_buffer_tuning_guide.sh --profile message-delivery-backend
#   sudo ./network_buffer_tuning_guide.sh --apply message-delivery-internet
#
# AUTHOR: Generated for linux-network-buffer-tuning project
# REQUIRES: root/sudo, sysctl, netstat/ss, ethtool, tc
#
################################################################################

set -euo pipefail

# Color definitions for clear, readable output
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RED='\033[91m'
readonly COLOR_GREEN='\033[92m'
readonly COLOR_YELLOW='\033[93m'
readonly COLOR_BLUE='\033[94m'
readonly COLOR_CYAN='\033[96m'
readonly COLOR_GRAY='\033[90m'

# Check if running as root or with sudo available
# Read-only mode works without root; apply mode requires root
IS_ROOT=0
if [ "$EUID" -eq 0 ]; then
    IS_ROOT=1
fi

################################################################################
# SECTION 1: DYNAMIC INTERFACE DETECTION
################################################################################

# Detect default network interface dynamically (follows project standards)
INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo -e "${COLOR_RED}Error: Could not determine default network interface${COLOR_RESET}"
    echo "Usage: $0 [--profile PROFILE] [--apply PROFILE]"
    echo "Profiles: message-delivery-backend, message-delivery-internet, file-transfer-backend, file-transfer-internet"
    exit 1
fi

################################################################################
# SECTION 2: PROFILE DEFINITIONS
################################################################################

# Define optimal buffer profiles for each use case and deployment
declare -A PROFILES=(
    # MESSAGE DELIVERY - BACKEND (Datacenter, 1-5ms RTT, 1-2KB messages)
    ["message-delivery-backend.tcp_rmem"]="4096 32768 131072"
    ["message-delivery-backend.tcp_wmem"]="4096 32768 131072"
    ["message-delivery-backend.rmem_max"]="131072"
    ["message-delivery-backend.wmem_max"]="131072"
    ["message-delivery-backend.rmem_default"]="32768"
    ["message-delivery-backend.wmem_default"]="32768"
    ["message-delivery-backend.tcp_mem"]="131072 262144 524288"

    # MESSAGE DELIVERY - INTERNET (Customer-facing, 50-200ms RTT, 1-2KB messages)
    ["message-delivery-internet.tcp_rmem"]="4096 262144 4194304"
    ["message-delivery-internet.tcp_wmem"]="4096 262144 4194304"
    ["message-delivery-internet.rmem_max"]="4194304"
    ["message-delivery-internet.wmem_max"]="4194304"
    ["message-delivery-internet.rmem_default"]="262144"
    ["message-delivery-internet.wmem_default"]="262144"
    ["message-delivery-internet.tcp_mem"]="524288 1048576 2097152"

    # FILE TRANSFER - BACKEND (Datacenter, 1-5ms RTT, MB-GB files)
    ["file-transfer-backend.tcp_rmem"]="4096 262144 1048576"
    ["file-transfer-backend.tcp_wmem"]="4096 262144 1048576"
    ["file-transfer-backend.rmem_max"]="1048576"
    ["file-transfer-backend.wmem_max"]="1048576"
    ["file-transfer-backend.rmem_default"]="262144"
    ["file-transfer-backend.wmem_default"]="262144"
    ["file-transfer-backend.tcp_mem"]="524288 1048576 2097152"

    # FILE TRANSFER - INTERNET (Customer-facing, 50-200ms RTT, MB-GB files)
    ["file-transfer-internet.tcp_rmem"]="4096 4194304 16777216"
    ["file-transfer-internet.tcp_wmem"]="4096 4194304 16777216"
    ["file-transfer-internet.rmem_max"]="16777216"
    ["file-transfer-internet.wmem_max"]="16777216"
    ["file-transfer-internet.rmem_default"]="4194304"
    ["file-transfer-internet.wmem_default"]="4194304"
    ["file-transfer-internet.tcp_mem"]="2097152 4194304 8388608"
)

################################################################################
# SECTION 3: UTILITY FUNCTIONS
################################################################################

# Get sysctl value with graceful fallback for non-root users
get_sysctl() {
    local param=$1
    # Try direct read first (works in read-only mode on some systems)
    local value=$(sysctl -n "$param" 2>/dev/null)
    if [ -z "$value" ]; then
        # Fallback: try reading from /proc/sys (if available)
        local proc_path="/proc/sys/${param//.//}"
        if [ -f "$proc_path" ]; then
            value=$(cat "$proc_path" 2>/dev/null | tr '\n' ' ' | xargs)
        fi
    fi
    echo "$value"
}

# Convert bytes to human-readable format
bytes_to_mb() {
    local bytes=$1
    echo "scale=2; $bytes / 1048576" | bc
}

bytes_to_kb() {
    local bytes=$1
    echo "scale=2; $bytes / 1024" | bc
}

# Format numbers with thousand separators for readability
format_number() {
    local num=$1
    printf "%'d" "$num"
}

# Print colored header
print_header() {
    local text="$1"
    echo -e "\n${COLOR_BOLD}${COLOR_BLUE}═══ $text ═══${COLOR_RESET}"
}

# Print colored subheader
print_subheader() {
    local text="$1"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}→ $text${COLOR_RESET}"
}

# Print status with color
print_status() {
    local status="$1"
    local message="$2"

    case "$status" in
        PASS|✓)
            echo -e "${COLOR_GREEN}✓${COLOR_RESET} $message"
            ;;
        FAIL|✗)
            echo -e "${COLOR_RED}✗${COLOR_RESET} $message"
            ;;
        WARN|⚠)
            echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $message"
            ;;
        INFO|ℹ)
            echo -e "${COLOR_BLUE}ℹ${COLOR_RESET} $message"
            ;;
    esac
}

# Print parameter comparison
print_comparison() {
    local param="$1"
    local current="$2"
    local recommended="$3"
    local status="$4"

    printf "  %-25s Current: %-15s | Recommended: %-15s [%s]\n" \
        "$param" "$current" "$recommended" "$status"
}

################################################################################
# SECTION 4: CURRENT CONFIGURATION ANALYSIS
################################################################################

get_current_config() {
    # Get core limits using graceful helper function
    RMEM_MAX=$(get_sysctl net.core.rmem_max)
    WMEM_MAX=$(get_sysctl net.core.wmem_max)
    RMEM_DEFAULT=$(get_sysctl net.core.rmem_default)
    WMEM_DEFAULT=$(get_sysctl net.core.wmem_default)

    # Get TCP settings using graceful helper function
    TCP_RMEM=$(get_sysctl net.ipv4.tcp_rmem)
    TCP_WMEM=$(get_sysctl net.ipv4.tcp_wmem)
    read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
    read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"

    # Get TCP memory - initialize variables to prevent unbound variable errors
    TCP_MEM=$(get_sysctl net.ipv4.tcp_mem)
    read TCP_MEM_LOW TCP_MEM_PRESS TCP_MEM_HIGH <<< "$TCP_MEM"
    # Ensure variables are set even if read fails
    TCP_MEM_LOW=${TCP_MEM_LOW:-0}
    TCP_MEM_PRESS=${TCP_MEM_PRESS:-0}
    TCP_MEM_HIGH=${TCP_MEM_HIGH:-0}

    # Get other settings using graceful helper function
    WINDOW_SCALING=$(get_sysctl net.ipv4.tcp_window_scaling)
    AUTO_TUNING=$(get_sysctl net.ipv4.tcp_moderate_rcvbuf)
    TCP_CONGESTION=$(get_sysctl net.ipv4.tcp_congestion_control)
    ECN=$(get_sysctl net.ipv4.tcp_ecn)
    TCP_FASTOPEN=$(get_sysctl net.ipv4.tcp_fastopen)

    # Get interface stats - may require sudo on some systems
    INTERFACE_MTU=$(ip link show $INTERFACE 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "0")
    INTERFACE_MTU=${INTERFACE_MTU:-0}
    INTERFACE_QLEN=$(ip link show $INTERFACE 2>/dev/null | grep -oP 'qlen \K[0-9]+' || echo "0")
    INTERFACE_QLEN=${INTERFACE_QLEN:-0}
}

################################################################################
# SECTION 5: CONSISTENCY CHECKING
################################################################################

check_buffer_hierarchy_consistency() {
    print_header "BUFFER HIERARCHY CONSISTENCY ANALYSIS"

    local errors=0
    local warnings=0

    # Check 1: tcp_rmem[2] <= rmem_max
    print_subheader "Core Buffer Limits"
    if (( TCP_RMEM_MAX > RMEM_MAX )); then
        print_status FAIL "tcp_rmem[2] ($(format_number $TCP_RMEM_MAX)) exceeds rmem_max ($(format_number $RMEM_MAX))"
        echo "         → Auto-tuning will be LIMITED to $RMEM_MAX"
        ((errors++))
    else
        print_status PASS "tcp_rmem[2] ≤ rmem_max"
    fi

    if (( TCP_WMEM_MAX > WMEM_MAX )); then
        print_status FAIL "tcp_wmem[2] ($(format_number $TCP_WMEM_MAX)) exceeds wmem_max ($(format_number $WMEM_MAX))"
        ((errors++))
    else
        print_status PASS "tcp_wmem[2] ≤ wmem_max"
    fi

    # Check 2: Window scaling for large buffers
    print_subheader "TCP Window Scaling"
    if (( TCP_RMEM_MAX > 65536 )) && [[ $WINDOW_SCALING -ne 1 ]]; then
        print_status FAIL "Window scaling DISABLED but buffers > 64KB"
        echo "         → Large windows won't be used by TCP"
        ((errors++))
    else
        print_status PASS "Window scaling properly configured"
    fi

    # Check 3: Auto-tuning enabled
    print_subheader "TCP Auto-Tuning"
    if [[ $AUTO_TUNING -ne 1 ]]; then
        print_status WARN "Auto-tuning DISABLED (tcp_moderate_rcvbuf = 0)"
        echo "         → Applications must manually set SO_RCVBUF"
        ((warnings++))
    else
        print_status PASS "Auto-tuning enabled"
    fi

    # Check 4: Minimum buffer sanity
    print_subheader "Minimum Buffer Values"
    if (( TCP_RMEM_MIN < 4096 )); then
        print_status WARN "tcp_rmem[0] ($TCP_RMEM_MIN) is very small"
        ((warnings++))
    else
        print_status PASS "tcp_rmem[0] appropriate"
    fi

    # Check 5: Default buffer sanity
    print_subheader "Default Buffer Values"
    if (( TCP_RMEM_DEF < 4096 )); then
        print_status FAIL "tcp_rmem[1] ($TCP_RMEM_DEF) is too small"
        echo "         → Default connections won't have adequate buffers"
        ((errors++))
    else
        print_status PASS "tcp_rmem[1] appropriate"
    fi

    echo ""
    echo "Summary: $errors errors, $warnings warnings"
    return $errors
}

################################################################################
# SECTION 6: MEMORY USAGE ANALYSIS
################################################################################

check_memory_pressure() {
    print_header "TCP MEMORY USAGE AND PRESSURE ANALYSIS"

    # Get current memory usage - initialize to 0 to prevent unbound variable errors
    CURRENT_PAGES=$(cat /proc/net/sockstat 2>/dev/null | grep "^TCP:" | awk '{print $11}' || echo "0")
    CURRENT_PAGES=${CURRENT_PAGES:-0}
    CURRENT_MB=$((CURRENT_PAGES * 4 / 1024))

    LOW_MB=$((TCP_MEM_LOW * 4 / 1024))
    PRESS_MB=$((TCP_MEM_PRESS * 4 / 1024))
    HIGH_MB=$((TCP_MEM_HIGH * 4 / 1024))

    # Calculate percentages
    LOW_PCT=$((CURRENT_PAGES * 100 / TCP_MEM_LOW))
    PRESS_PCT=$((CURRENT_PAGES * 100 / TCP_MEM_PRESS))
    HIGH_PCT=$((CURRENT_PAGES * 100 / TCP_MEM_HIGH))

    print_subheader "Current Memory Usage"
    echo "  Current:     $CURRENT_PAGES pages (~${CURRENT_MB}MB)"
    echo "  Low (3%):    $TCP_MEM_LOW pages (~${LOW_MB}MB) - at ${LOW_PCT}%"
    echo "  Pressure:    $TCP_MEM_PRESS pages (~${PRESS_MB}MB) - at ${PRESS_PCT}%"
    echo "  High (12%):  $TCP_MEM_HIGH pages (~${HIGH_MB}MB) - at ${HIGH_PCT}%"
    echo ""

    # Status assessment
    print_subheader "Memory Pressure Status"
    if (( CURRENT_PAGES > TCP_MEM_HIGH )); then
        print_status FAIL "CRITICAL: Memory exceeds hard limit!"
        echo "           TCP will reject new connections"
    elif (( CURRENT_PAGES > TCP_MEM_PRESS )); then
        print_status WARN "WARNING: Memory pressure activated"
        echo "          TCP reducing allocations for new connections"
    elif (( CURRENT_PAGES > TCP_MEM_LOW )); then
        print_status INFO "INFO: Memory in normal operating range"
    else
        print_status PASS "Memory usage healthy"
    fi

    # Connection stats - initialize to 0 to prevent unbound variable errors
    print_subheader "Active Connections"
    INUSE=$(cat /proc/net/sockstat 2>/dev/null | grep "^TCP:" | awk '{print $3}' || echo "0")
    INUSE=${INUSE:-0}
    ORPHAN=$(cat /proc/net/sockstat 2>/dev/null | grep "^TCP:" | awk '{print $5}' || echo "0")
    ORPHAN=${ORPHAN:-0}

    echo "  In Use:      $(format_number $INUSE) connections"
    echo "  Orphaned:    $(format_number $ORPHAN) sockets"

    # Estimate average buffer size
    if (( INUSE > 0 )); then
        AVG_BUFFER=$((CURRENT_PAGES * 4096 / INUSE))
        echo "  Avg Buffer:  $AVG_BUFFER bytes per connection"
    fi
}

################################################################################
# SECTION 7: SOCKET BUFFER INSPECTION
################################################################################

check_socket_buffers() {
    print_header "ACTIVE SOCKET BUFFER USAGE"

    print_subheader "Sample of Active Connections (max 5)"

    # Get sample connections
    local count=0
    ss -tm 2>/dev/null | tail -n +2 | head -5 | while read line; do
        if [ $count -lt 5 ]; then
            echo "  $line"
            ((count++))
        fi
    done

    echo ""
    print_subheader "Format Interpretation"
    echo "  r  = bytes in receive queue"
    echo "  rb = receive buffer limit (SO_RCVBUF)"
    echo "  t  = bytes in send queue"
    echo "  tb = send buffer limit (SO_SNDBUF)"

    # Check for buffer saturation
    print_subheader "Buffer Saturation Check"
    local saturated=0

    # Using netstat for compatibility
    if command -v ss &> /dev/null; then
        # Count connections with buffers over 80% full
        saturated=$(ss -tm 2>/dev/null | grep skmem | awk -F'[(),]' '{
            # Parse skmem values
            for (i=2; i<=NF; i++) {
                if ($i ~ /^r/) recv=$i
                if ($i ~ /^rb/) rbuf=$i
            }
            # Check if receive queue > 80% of buffer limit
            gsub(/[^0-9]/, "", recv); gsub(/[^0-9]/, "", rbuf)
            if (rbuf > 0 && recv > 0 && recv * 100 / rbuf > 80) {
                print 1
            }
        }' | wc -l)

        if (( saturated > 0 )); then
            print_status WARN "Found $saturated connections with >80% buffer saturation"
            echo "           Potential for packet drops"
        else
            print_status PASS "No connections with excessive buffer saturation"
        fi
    fi
}

################################################################################
# SECTION 8: PAIN POINTS AND HOT SPOTS IDENTIFICATION
################################################################################

identify_pain_points() {
    print_header "PAIN POINTS AND HOT SPOTS REQUIRING ATTENTION"

    local issues=()
    local critical=0

    # Pain Point 1: Hierarchy inconsistency
    if (( TCP_RMEM_MAX > RMEM_MAX )) || (( TCP_WMEM_MAX > WMEM_MAX )); then
        issues+=("CRITICAL: Buffer hierarchy inconsistency")
        issues+=("  → Auto-tuning is limited or disabled")
        issues+=("  → Applications cannot use full allocated capacity")
        ((critical++))
    fi

    # Pain Point 2: Small buffers for large RTT
    if (( TCP_RMEM_MAX < 262144 )); then
        issues+=("WARNING: Small max buffers (< 256KB)")
        issues+=("  → May be inadequate for Internet deployments (50-200ms RTT)")
        issues+=("  → File transfers will have reduced throughput")
    fi

    # Pain Point 3: Large buffers for small RTT
    if (( TCP_RMEM_MAX > 4194304 )); then
        issues+=("WARNING: Very large max buffers (> 4MB)")
        issues+=("  → Excessive for datacenter deployments (1-5ms RTT)")
        issues+=("  → May increase latency and memory usage")
    fi

    # Pain Point 4: Memory pressure approaching
    if (( CURRENT_PAGES > TCP_MEM_PRESS )); then
        issues+=("CRITICAL: Approaching memory pressure")
        issues+=("  → TCP may start rejecting new connections")
        issues+=("  → Consider reducing buffer sizes or increasing limits")
        ((critical++))
    fi

    # Pain Point 5: Disabled window scaling
    if (( TCP_RMEM_MAX > 65536 )) && [[ $WINDOW_SCALING -ne 1 ]]; then
        issues+=("CRITICAL: Window scaling disabled with large buffers")
        issues+=("  → TCP windows capped at 64KB")
        issues+=("  → Cannot fully utilize bandwidth")
        ((critical++))
    fi

    # Pain Point 6: Small default buffers
    if (( TCP_RMEM_DEF < 32768 )); then
        issues+=("WARNING: Small default buffers (< 32KB)")
        issues+=("  → New connections start with limited capacity")
        issues+=("  → Auto-tuning must increase them dynamically")
    fi

    # Pain Point 7: Interface MTU issues
    if (( INTERFACE_MTU != 1500 )) && (( INTERFACE_MTU != 9000 )); then
        issues+=("WARNING: Unusual MTU ($INTERFACE_MTU)")
        issues+=("  → Standard is 1500 (Ethernet) or 9000 (Jumbo)")
        issues+=("  → Check network configuration consistency")
    fi

    # Pain Point 8: No CCAs configured
    if [[ "$TCP_CONGESTION" == "cubic" ]]; then
        issues+=("INFO: Using CUBIC congestion control (default)")
        issues+=("  → Consider BBR for more stable latency")
    fi

    if [ ${#issues[@]} -eq 0 ]; then
        print_status PASS "No critical issues detected"
        echo "  Configuration appears well-optimized"
    else
        echo ""
        for issue in "${issues[@]}"; do
            if [[ $issue =~ ^CRITICAL ]]; then
                print_status FAIL "${issue#CRITICAL: }"
            elif [[ $issue =~ ^WARNING ]]; then
                print_status WARN "${issue#WARNING: }"
            elif [[ $issue =~ ^INFO ]]; then
                print_status INFO "${issue#INFO: }"
            else
                echo "    $issue"
            fi
        done
    fi

    echo ""
    echo "Critical issues found: $critical"
}

################################################################################
# SECTION 9: PROFILE COMPARISON AND RECOMMENDATIONS
################################################################################

generate_profile_comparison() {
    local target_profile="$1"

    print_header "PROFILE COMPARISON: Current vs Recommended"
    echo "Target Profile: ${COLOR_BOLD}$target_profile${COLOR_RESET}"
    echo ""

    # Extract recommended values for this profile
    local tcp_rmem_rec="${PROFILES[$target_profile.tcp_rmem]}"
    local tcp_wmem_rec="${PROFILES[$target_profile.tcp_wmem]}"
    local rmem_max_rec="${PROFILES[$target_profile.rmem_max]}"
    local wmem_max_rec="${PROFILES[$target_profile.wmem_max]}"
    local rmem_default_rec="${PROFILES[$target_profile.rmem_default]}"
    local wmem_default_rec="${PROFILES[$target_profile.wmem_default]}"
    local tcp_mem_rec="${PROFILES[$target_profile.tcp_mem]}"

    read tcp_rmem_rec_min tcp_rmem_rec_def tcp_rmem_rec_max <<< "$tcp_rmem_rec"
    read tcp_wmem_rec_min tcp_wmem_rec_def tcp_wmem_rec_max <<< "$tcp_wmem_rec"
    read tcp_mem_rec_low tcp_mem_rec_press tcp_mem_rec_high <<< "$tcp_mem_rec"

    print_subheader "Core Buffer Limits"

    # Compare rmem_max
    if (( RMEM_MAX == rmem_max_rec )); then
        print_status PASS "rmem_max is optimal"
    else
        printf "  %-25s Current: %-15s | Recommended: %-15s\n" \
            "rmem_max" "$(format_number $RMEM_MAX)" "$(format_number $rmem_max_rec)"
    fi

    # Compare wmem_max
    if (( WMEM_MAX == wmem_max_rec )); then
        print_status PASS "wmem_max is optimal"
    else
        printf "  %-25s Current: %-15s | Recommended: %-15s\n" \
            "wmem_max" "$(format_number $WMEM_MAX)" "$(format_number $wmem_max_rec)"
    fi

    echo ""
    print_subheader "TCP Auto-Tuning (Min, Default, Max)"

    # Compare tcp_rmem
    if [[ "$TCP_RMEM" == "$tcp_rmem_rec" ]]; then
        print_status PASS "tcp_rmem is optimal"
    else
        echo "  tcp_rmem:"
        printf "    Current:      %s | %s | %s\n" $TCP_RMEM_MIN $TCP_RMEM_DEF $TCP_RMEM_MAX
        printf "    Recommended:  %s | %s | %s\n" $tcp_rmem_rec_min $tcp_rmem_rec_def $tcp_rmem_rec_max
    fi

    # Compare tcp_wmem
    if [[ "$TCP_WMEM" == "$tcp_wmem_rec" ]]; then
        print_status PASS "tcp_wmem is optimal"
    else
        echo "  tcp_wmem:"
        printf "    Current:      %s | %s | %s\n" $TCP_WMEM_MIN $TCP_WMEM_DEF $TCP_WMEM_MAX
        printf "    Recommended:  %s | %s | %s\n" $tcp_wmem_rec_min $tcp_wmem_rec_def $tcp_wmem_rec_max
    fi

    echo ""
    print_subheader "TCP Memory Limits (Low, Pressure, High)"
    if [[ "$TCP_MEM" == "$tcp_mem_rec" ]]; then
        print_status PASS "tcp_mem is optimal"
    else
        echo "  tcp_mem:"
        printf "    Current:      %s | %s | %s pages\n" $TCP_MEM_LOW $TCP_MEM_PRESS $TCP_MEM_HIGH
        printf "    Recommended:  %s | %s | %s pages\n" $tcp_mem_rec_low $tcp_mem_rec_press $tcp_mem_rec_high
    fi
}

################################################################################
# SECTION 10: REMEDIATION COMMANDS
################################################################################

generate_remediation_commands() {
    local target_profile="$1"

    print_header "REMEDIATION COMMANDS"
    echo "Profile: ${COLOR_BOLD}$target_profile${COLOR_RESET}"
    echo ""

    # Extract recommended values
    local tcp_rmem_rec="${PROFILES[$target_profile.tcp_rmem]}"
    local tcp_wmem_rec="${PROFILES[$target_profile.tcp_wmem]}"
    local rmem_max_rec="${PROFILES[$target_profile.rmem_max]}"
    local wmem_max_rec="${PROFILES[$target_profile.wmem_max]}"
    local rmem_default_rec="${PROFILES[$target_profile.rmem_default]}"
    local wmem_default_rec="${PROFILES[$target_profile.wmem_default]}"
    local tcp_mem_rec="${PROFILES[$target_profile.tcp_mem]}"

    print_subheader "Option 1: Apply changes temporarily (lost on reboot)"
    echo "cat << 'EOF' | while read cmd; do"
    echo "    echo \"\$cmd\" | sudo tee /proc/sys/\${cmd//.//} > /dev/null"
    echo "done"
    echo "net.core.rmem_max = $rmem_max_rec"
    echo "net.core.wmem_max = $wmem_max_rec"
    echo "net.ipv4.tcp_rmem = $tcp_rmem_rec"
    echo "net.ipv4.tcp_wmem = $tcp_wmem_rec"
    echo "net.ipv4.tcp_mem = $tcp_mem_rec"
    echo "EOF"

    echo ""
    print_subheader "Option 2: Make changes persistent (recommended)"
    echo "cat > /etc/sysctl.d/99-network-tuning.conf << 'EOF'"
    echo "# Network Buffer Tuning for $target_profile"
    echo "# Generated by network_buffer_tuning_guide.sh"
    echo "# Applied: $(date)"
    echo ""
    echo "net.core.rmem_max = $rmem_max_rec"
    echo "net.core.wmem_max = $wmem_max_rec"
    echo "net.core.rmem_default = $rmem_default_rec"
    echo "net.core.wmem_default = $wmem_default_rec"
    echo "net.ipv4.tcp_rmem = $tcp_rmem_rec"
    echo "net.ipv4.tcp_wmem = $tcp_wmem_rec"
    echo "net.ipv4.tcp_mem = $tcp_mem_rec"
    echo ""
    echo "# Recommended supporting parameters"
    echo "net.ipv4.tcp_window_scaling = 1"
    echo "net.ipv4.tcp_moderate_rcvbuf = 1"
    echo "net.ipv4.tcp_congestion_control = bbr"
    echo "net.ipv4.tcp_ecn = 1"
    echo "EOF"
    echo ""
    echo "sudo sysctl -p /etc/sysctl.d/99-network-tuning.conf"

    echo ""
    print_subheader "Option 3: Apply with automatic backup"
    echo "# Create timestamped backup"
    echo "BACKUP_FILE=\"/root/sysctl-backup-\$(date +%s).conf\""
    echo "sysctl -a > \"\$BACKUP_FILE\""
    echo "echo \"Backup created: \$BACKUP_FILE\""
    echo ""
    echo "# Apply new configuration"
    echo "sudo sysctl -w net.core.rmem_max=$rmem_max_rec"
    echo "sudo sysctl -w net.core.wmem_max=$wmem_max_rec"
    echo "sudo sysctl -w 'net.ipv4.tcp_rmem=$tcp_rmem_rec'"
    echo "sudo sysctl -w 'net.ipv4.tcp_wmem=$tcp_wmem_rec'"
    echo "sudo sysctl -w 'net.ipv4.tcp_mem=$tcp_mem_rec'"
    echo ""
    echo "# Rollback if needed:"
    echo "# sysctl -p \$BACKUP_FILE"
}

################################################################################
# SECTION 11: PROFILE DESCRIPTIONS
################################################################################

print_profile_descriptions() {
    print_header "TUNING PROFILES EXPLAINED"

    echo ""
    echo -e "${COLOR_BOLD}MESSAGE DELIVERY - BACKEND${COLOR_RESET} (Datacenter, 1-5ms RTT)"
    echo "  Use case: Internal service-to-service communication with small 1-2KB messages"
    echo "  RTT: 1-5ms (low latency, stable)"
    echo "  Focus: Minimize absolute latency, reduce queuing"
    echo "  Buffer strategy: Small buffers (32-128KB) to reduce buffering delay"
    echo "  Throughput: Secondary concern, latency is primary"
    echo ""

    echo -e "${COLOR_BOLD}MESSAGE DELIVERY - INTERNET${COLOR_RESET} (Customer-facing, 50-200ms RTT)"
    echo "  Use case: External APIs, customer-facing endpoints with 1-2KB messages"
    echo "  RTT: 50-200ms (high variable latency)"
    echo "  Focus: Reliability with resilience to packet loss and jitter"
    echo "  Buffer strategy: Medium buffers (256-512KB) for stable delivery"
    echo "  Throughput: Important but latency predictability matters more"
    echo ""

    echo -e "${COLOR_BOLD}FILE TRANSFER - BACKEND${COLOR_RESET} (Datacenter, 1-5ms RTT)"
    echo "  Use case: High-speed file transfers within datacenter (MB-GB files)"
    echo "  RTT: 1-5ms (low latency, stable)"
    echo "  Focus: High throughput with minimal latency variance"
    echo "  Buffer strategy: Large buffers (256KB-1MB) to maximize throughput"
    echo "  Throughput: Primary concern, utilize full bandwidth"
    echo ""

    echo -e "${COLOR_BOLD}FILE TRANSFER - INTERNET${COLOR_RESET} (Cross-region, 50-200ms RTT)"
    echo "  Use case: WAN file transfers across regions (MB-GB files)"
    echo "  RTT: 50-200ms (high latency)"
    echo "  Focus: Maximum throughput over long distances"
    echo "  Buffer strategy: Very large buffers (4-16MB) to utilize BDP"
    echo "  Throughput: Absolute priority, throughput = Bandwidth × RTT"
}

################################################################################
# SECTION 12: MAIN EXECUTION FLOW
################################################################################

main() {
    local profile="${1:-}"
    local apply_flag=false

    # Parse command line arguments
    case "$profile" in
        --apply)
            apply_flag=true
            profile="${2:-}"
            if [ -z "$profile" ]; then
                echo "Error: --apply requires a profile name"
                echo "Available profiles:"
                echo "  message-delivery-backend"
                echo "  message-delivery-internet"
                echo "  file-transfer-backend"
                echo "  file-transfer-internet"
                exit 1
            fi
            ;;
        --profile)
            profile="${2:-}"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "OPTIONS:"
            echo "  (no args)              Show current configuration analysis"
            echo "  --profile PROFILE      Compare against specific profile"
            echo "  --apply PROFILE        Apply profile settings (CAREFUL!)"
            echo ""
            echo "PROFILES:"
            echo "  message-delivery-backend   (Datacenter, 1-2KB messages)"
            echo "  message-delivery-internet  (Internet, 1-2KB messages)"
            echo "  file-transfer-backend      (Datacenter, MB-GB files)"
            echo "  file-transfer-internet     (Internet, MB-GB files)"
            exit 0
            ;;
    esac

    # Header
    clear
    echo -e "${COLOR_BOLD}${COLOR_CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║     NETWORK BUFFER TUNING GUIDE & ANALYSIS                   ║"
    echo "║                                                              ║"
    echo "║     Comprehensive buffer configuration analysis              ║"
    echo "║     for RHEL/OEL 8 network optimization                      ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${COLOR_RESET}"

    # Display permission mode
    if [ "$IS_ROOT" -eq 1 ]; then
        echo -e "${COLOR_GREEN}✓ Running as root - Full read/write access enabled${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}⚠ Running as regular user - Read-only mode (analysis only)${COLOR_RESET}"
        echo "   To apply changes with --apply flag, use: sudo $0 ..."
    fi
    echo ""

    # Get current configuration
    get_current_config

    # Display current settings
    print_header "CURRENT CONFIGURATION SNAPSHOT"
    print_subheader "Network Interface"
    echo "  Interface: $INTERFACE"
    echo "  MTU: $INTERFACE_MTU"
    echo "  TX Queue Length: $INTERFACE_QLEN"
    echo "  Congestion Control: $TCP_CONGESTION"
    echo "  ECN: $ECN"
    echo ""

    print_subheader "Buffer Configuration"
    echo "  rmem_max: $(format_number $RMEM_MAX) bytes (~$(bytes_to_kb $RMEM_MAX)KB)"
    echo "  wmem_max: $(format_number $WMEM_MAX) bytes (~$(bytes_to_kb $WMEM_MAX)KB)"
    echo "  rmem_default: $(format_number $RMEM_DEFAULT) bytes"
    echo "  wmem_default: $(format_number $WMEM_DEFAULT) bytes"
    echo "  tcp_rmem: $TCP_RMEM"
    echo "  tcp_wmem: $TCP_WMEM"
    echo "  tcp_mem: $TCP_MEM pages"
    echo ""

    # Run all analysis
    check_buffer_hierarchy_consistency
    check_memory_pressure
    check_socket_buffers
    identify_pain_points

    # Print profile descriptions
    print_profile_descriptions

    # If profile specified, compare
    if [ -n "$profile" ]; then
        if [[ ! "${!PROFILES[@]}" =~ "${profile}" ]]; then
            echo -e "${COLOR_RED}Error: Unknown profile '$profile'${COLOR_RESET}"
            echo "Available profiles:"
            echo "  message-delivery-backend"
            echo "  message-delivery-internet"
            echo "  file-transfer-backend"
            echo "  file-transfer-internet"
            exit 1
        fi

        generate_profile_comparison "$profile"
        generate_remediation_commands "$profile"

        if [ "$apply_flag" = true ]; then
            # Check if running as root for apply mode
            if [ "$IS_ROOT" -ne 1 ]; then
                print_header "ROOT ACCESS REQUIRED"
                print_status FAIL "The --apply flag requires root privileges"
                echo ""
                echo "To apply configuration changes, please use sudo:"
                echo "  sudo $0 --apply $profile"
                echo ""
                exit 1
            fi

            print_header "APPLYING CONFIGURATION"
            echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: This will change system network parameters!${COLOR_RESET}"
            echo "Make sure you understand the impact before proceeding."
            echo ""

            # Create backup
            BACKUP_FILE="/root/sysctl-backup-$(date +%s).conf"
            echo "Creating backup in $BACKUP_FILE..."
            sysctl -a > "$BACKUP_FILE"
            print_status PASS "Backup created"
            echo ""

            # Apply settings
            echo "Applying configuration..."
            local tcp_rmem_rec="${PROFILES[$profile.tcp_rmem]}"
            local tcp_wmem_rec="${PROFILES[$profile.tcp_wmem]}"
            local rmem_max_rec="${PROFILES[$profile.rmem_max]}"
            local wmem_max_rec="${PROFILES[$profile.wmem_max]}"
            local tcp_mem_rec="${PROFILES[$profile.tcp_mem]}"

            sysctl -w net.core.rmem_max=$rmem_max_rec > /dev/null
            sysctl -w net.core.wmem_max=$wmem_max_rec > /dev/null
            sysctl -w "net.ipv4.tcp_rmem=$tcp_rmem_rec" > /dev/null
            sysctl -w "net.ipv4.tcp_wmem=$tcp_wmem_rec" > /dev/null
            sysctl -w "net.ipv4.tcp_mem=$tcp_mem_rec" > /dev/null

            print_status PASS "Configuration applied"
            echo ""

            # Verify
            echo "Verifying changes..."
            local verify_rmem=$(sysctl -n net.core.rmem_max)
            if [ "$verify_rmem" = "$rmem_max_rec" ]; then
                print_status PASS "Changes verified successfully"
            else
                print_status FAIL "Verification failed!"
                echo "To rollback: sysctl -p $BACKUP_FILE"
            fi
        fi
    fi

    # Footer
    echo ""
    print_header "NEXT STEPS"
    echo "1. Review the pain points identified in this analysis"
    echo "2. Select appropriate profile for your use case and deployment:"
    echo "   - Run: $0 --profile message-delivery-backend"
    echo "   - Run: $0 --profile message-delivery-internet"
    echo "   - Run: $0 --profile file-transfer-backend"
    echo "   - Run: $0 --profile file-transfer-internet"
    echo ""
    echo "3. When ready to apply: $0 --apply <profile-name>"
    echo ""
    echo "4. Validate with: /opt/scripts/quick_network_buffer_consistency_check.sh"
    echo "5. Monitor with: /opt/scripts/network_buffer_audit.sh"
    echo ""
    echo "For more information:"
    echo "  See: /root/linux-network-buffer-tuning/CLAUDE.md"
    echo "  See: /root/linux-network-buffer-tuning/08-low-latency-profile.md"
}

# Run main function
main "$@"
