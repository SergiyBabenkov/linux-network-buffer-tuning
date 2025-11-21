#!/bin/bash
#
# network_buffer_audit.sh
# Comprehensive audit of Linux network buffer configuration
# For high-speed, low-latency systems
#
# Usage: sudo ./network_buffer_audit.sh [--fix] [--profile=<type>]
# Profiles: high-bandwidth | low-latency | balanced | ultra-low-latency
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Script configuration
APPLY_FIX=false
PROFILE="balanced"
REPORT_FILE="/tmp/network_audit_$(date +%Y%m%d_%H%M%S).txt"
SYSCTL_BACKUP="/tmp/sysctl_backup_$(date +%Y%m%d_%H%M%S).conf"

# Initialize system variables (MUST be before they're used)
TOTAL_RAM=0
TOTAL_RAM_GB=0
CPU_CORES=0
INTERFACES=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --fix)
            APPLY_FIX=true
            shift
            ;;
        --profile=*)
            PROFILE="${arg#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [--fix] [--profile=<type>]"
            echo "Profiles: high-bandwidth | low-latency | balanced | ultra-low-latency"
            exit 0
            ;;
    esac
done

# Check if running as root (required only for --fix mode)
IS_ROOT=0
if [[ $EUID -eq 0 ]]; then
    IS_ROOT=1
fi

# If not root and --fix flag used, show error
if [[ $IS_ROOT -eq 0 && $APPLY_FIX == true ]]; then
    echo -e "${RED}Error: --fix flag requires root privileges${NC}"
    echo "To fix issues, run with sudo:"
    echo "  sudo $0 --fix --profile=$PROFILE"
    exit 1
fi

# Helper functions
print_header() {
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${BOLD}${GREEN}▶ $1${NC}"
    echo "───────────────────────────────────────────────────────────"
}

print_issue() {
    local severity=$1
    local message=$2
    case $severity in
        CRITICAL)
            echo -e "${RED}[CRITICAL]${NC} $message" | tee -a "$REPORT_FILE"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$REPORT_FILE"
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} $message" | tee -a "$REPORT_FILE"
            ;;
        OK)
            echo -e "${GREEN}[OK]${NC} $message" | tee -a "$REPORT_FILE"
            ;;
    esac
}

get_sysctl() {
    local param=$1
    sysctl -n "$param" 2>/dev/null || echo "N/A"
}

bytes_to_human() {
    local bytes=$1
    if [[ $bytes == "N/A" ]]; then
        echo "N/A"
    elif (( bytes < 1024 )); then
        echo "${bytes}B"
    elif (( bytes < 1048576 )); then
        echo "$(( bytes / 1024 ))KB"
    elif (( bytes < 1073741824 )); then
        echo "$(( bytes / 1048576 ))MB"
    else
        echo "$(( bytes / 1073741824 ))GB"
    fi
}

pages_to_bytes() {
    local pages=$1
    local page_size=$(getconf PAGESIZE)
    echo $(( pages * page_size ))
}

# Get system information - MUST be called early
get_system_info() {
    print_section "System Information"
    
    TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')
    TOTAL_RAM_GB=$(( TOTAL_RAM / 1073741824 ))
    CPU_CORES=$(nproc)
    INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -5)
    
    echo "Total RAM: $(bytes_to_human $TOTAL_RAM) (${TOTAL_RAM_GB}GB)"
    echo "CPU Cores: $CPU_CORES"
    echo "Active Interfaces: $(echo $INTERFACES | tr '\n' ' ')"
    
    # Get network card speeds
    for iface in $INTERFACES; do
        if [[ -e /sys/class/net/$iface/speed ]]; then
            speed=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "Unknown")
            if [[ $speed != "Unknown" && $speed != "-1" ]]; then
                echo "  - $iface: ${speed}Mbps"
            fi
        fi
    done
}

# Define tuning profiles based on use case
get_profile_recommendations() {
    # Ensure TOTAL_RAM is set
    if [[ $TOTAL_RAM -eq 0 ]]; then
        echo "ERROR: System information not gathered yet"
        exit 1
    fi
    
    case $PROFILE in
        high-bandwidth)
            # 10Gbps+ networks, bulk data transfer
            RMEM_MAX=$((128 * 1024 * 1024))      # 128MB
            WMEM_MAX=$((128 * 1024 * 1024))      # 128MB
            TCP_RMEM="4096 131072 67108864"      # 4KB, 128KB, 64MB
            TCP_WMEM="4096 65536 67108864"       # 4KB, 64KB, 64MB
            TCP_MEM_LOW=$((TOTAL_RAM / 32))      # ~3% of RAM
            TCP_MEM_PRESSURE=$((TOTAL_RAM / 16)) # ~6% of RAM
            TCP_MEM_HIGH=$((TOTAL_RAM / 8))      # ~12% of RAM
            NETDEV_MAX_BACKLOG=30000
            SOMAXCONN=4096
            TCP_MAX_SYN_BACKLOG=8192
            TXQUEUELEN=10000
            ;;
            
        low-latency)
            # Message delivery, latency-sensitive applications
            RMEM_MAX=$((16 * 1024 * 1024))       # 16MB
            WMEM_MAX=$((16 * 1024 * 1024))       # 16MB
            TCP_RMEM="4096 65536 4194304"        # 4KB, 64KB, 4MB
            TCP_WMEM="4096 16384 4194304"        # 4KB, 16KB, 4MB
            TCP_MEM_LOW=$((TOTAL_RAM / 64))      # ~1.5% of RAM
            TCP_MEM_PRESSURE=$((TOTAL_RAM / 32)) # ~3% of RAM
            TCP_MEM_HIGH=$((TOTAL_RAM / 16))     # ~6% of RAM
            NETDEV_MAX_BACKLOG=5000
            SOMAXCONN=2048
            TCP_MAX_SYN_BACKLOG=4096
            TXQUEUELEN=1000
            ;;

        ultra-low-latency)
            # Ultra low-latency message delivery (sub-millisecond requirements)
            RMEM_MAX=$((8 * 1024 * 1024))        # 8MB
            WMEM_MAX=$((8 * 1024 * 1024))        # 8MB
            TCP_RMEM="4096 32768 2097152"        # 4KB, 32KB, 2MB
            TCP_WMEM="4096 16384 2097152"        # 4KB, 16KB, 2MB
            TCP_MEM_LOW=$((TOTAL_RAM / 128))     # ~0.75% of RAM
            TCP_MEM_PRESSURE=$((TOTAL_RAM / 64)) # ~1.5% of RAM
            TCP_MEM_HIGH=$((TOTAL_RAM / 32))     # ~3% of RAM
            NETDEV_MAX_BACKLOG=2000
            SOMAXCONN=1024
            TCP_MAX_SYN_BACKLOG=2048
            TXQUEUELEN=500
            ;;
            
        balanced|*)
            # General purpose high-performance
            RMEM_MAX=$((32 * 1024 * 1024))       # 32MB
            WMEM_MAX=$((32 * 1024 * 1024))       # 32MB
            TCP_RMEM="4096 87380 16777216"       # 4KB, 85KB, 16MB
            TCP_WMEM="4096 65536 16777216"       # 4KB, 64KB, 16MB
            TCP_MEM_LOW=$((TOTAL_RAM / 32))      # ~3% of RAM
            TCP_MEM_PRESSURE=$((TOTAL_RAM / 16)) # ~6% of RAM
            TCP_MEM_HIGH=$((TOTAL_RAM / 8))      # ~12% of RAM
            NETDEV_MAX_BACKLOG=10000
            SOMAXCONN=4096
            TCP_MAX_SYN_BACKLOG=4096
            TXQUEUELEN=5000
            ;;
    esac
    
    # Convert to pages for tcp_mem
    local page_size=$(getconf PAGESIZE)
    TCP_MEM_LOW_PAGES=$((TCP_MEM_LOW / page_size))
    TCP_MEM_PRESSURE_PAGES=$((TCP_MEM_PRESSURE / page_size))
    TCP_MEM_HIGH_PAGES=$((TCP_MEM_HIGH / page_size))
}

# Audit Core Socket Buffers
audit_core_buffers() {
    print_section "Core Socket Buffers (All Socket Types)"
    
    local rmem_default=$(get_sysctl net.core.rmem_default)
    local rmem_max=$(get_sysctl net.core.rmem_max)
    local wmem_default=$(get_sysctl net.core.wmem_default)
    local wmem_max=$(get_sysctl net.core.wmem_max)
    
    echo "Current Settings:"
    echo "  rmem_default: $(bytes_to_human $rmem_default) ($rmem_default bytes)"
    echo "  rmem_max:     $(bytes_to_human $rmem_max) ($rmem_max bytes)"
    echo "  wmem_default: $(bytes_to_human $wmem_default) ($wmem_default bytes)"
    echo "  wmem_max:     $(bytes_to_human $wmem_max) ($wmem_max bytes)"
    
    echo -e "\nRecommended for $PROFILE profile:"
    echo "  rmem_max:     $(bytes_to_human $RMEM_MAX) ($RMEM_MAX bytes)"
    echo "  wmem_max:     $(bytes_to_human $WMEM_MAX) ($WMEM_MAX bytes)"
    
    # Check issues
    if (( rmem_max < RMEM_MAX )); then
        print_issue "WARNING" "rmem_max ($(bytes_to_human $rmem_max)) is below recommended $(bytes_to_human $RMEM_MAX)"
        [[ $APPLY_FIX == true ]] && sysctl -w net.core.rmem_max=$RMEM_MAX
    else
        print_issue "OK" "rmem_max is adequate"
    fi
    
    if (( wmem_max < WMEM_MAX )); then
        print_issue "WARNING" "wmem_max ($(bytes_to_human $wmem_max)) is below recommended $(bytes_to_human $WMEM_MAX)"
        [[ $APPLY_FIX == true ]] && sysctl -w net.core.wmem_max=$WMEM_MAX
    else
        print_issue "OK" "wmem_max is adequate"
    fi
}

# Audit TCP Buffers
audit_tcp_buffers() {
    print_section "TCP Buffer Configuration"
    
    local tcp_rmem=$(get_sysctl net.ipv4.tcp_rmem)
    local tcp_wmem=$(get_sysctl net.ipv4.tcp_wmem)
    local tcp_mem=$(get_sysctl net.ipv4.tcp_mem)
    
    echo "Current Settings:"
    echo "  tcp_rmem: $tcp_rmem"
    IFS=' ' read -r tcp_rmem_min tcp_rmem_def tcp_rmem_max <<< "$tcp_rmem"
    echo "    min:     $(bytes_to_human $tcp_rmem_min)"
    echo "    default: $(bytes_to_human $tcp_rmem_def)"
    echo "    max:     $(bytes_to_human $tcp_rmem_max)"
    
    echo "  tcp_wmem: $tcp_wmem"
    IFS=' ' read -r tcp_wmem_min tcp_wmem_def tcp_wmem_max <<< "$tcp_wmem"
    echo "    min:     $(bytes_to_human $tcp_wmem_min)"
    echo "    default: $(bytes_to_human $tcp_wmem_def)"
    echo "    max:     $(bytes_to_human $tcp_wmem_max)"
    
    echo "  tcp_mem: $tcp_mem (in pages)"
    IFS=' ' read -r tcp_mem_low tcp_mem_pres tcp_mem_high <<< "$tcp_mem"
    echo "    low:      $(bytes_to_human $(pages_to_bytes $tcp_mem_low))"
    echo "    pressure: $(bytes_to_human $(pages_to_bytes $tcp_mem_pres))"
    echo "    high:     $(bytes_to_human $(pages_to_bytes $tcp_mem_high))"
    
    echo -e "\nRecommended for $PROFILE profile:"
    echo "  tcp_rmem: $TCP_RMEM"
    echo "  tcp_wmem: $TCP_WMEM"
    echo "  tcp_mem:  $TCP_MEM_LOW_PAGES $TCP_MEM_PRESSURE_PAGES $TCP_MEM_HIGH_PAGES (pages)"
    
    # Critical check: tcp_rmem[2] vs rmem_max
    local rmem_max=$(get_sysctl net.core.rmem_max)
    IFS=' ' read -r _ _ recommended_tcp_rmem_max <<< "$TCP_RMEM"
    
    if (( tcp_rmem_max > rmem_max )); then
        print_issue "CRITICAL" "tcp_rmem[2] ($tcp_rmem_max) > rmem_max ($rmem_max) - auto-tuning will be LIMITED!"
        echo "  EXPLANATION: TCP auto-tuning cannot grow beyond rmem_max, wasting tcp_rmem[2] capacity"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_rmem="$TCP_RMEM"
    fi
    
    if (( tcp_wmem_max > $(get_sysctl net.core.wmem_max) )); then
        print_issue "CRITICAL" "tcp_wmem[2] > wmem_max - auto-tuning will be LIMITED!"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_wmem="$TCP_WMEM"
    fi
    
    # Check if values are too small for profile
    if (( tcp_rmem_max < recommended_tcp_rmem_max )); then
        print_issue "WARNING" "tcp_rmem[2] is below recommended for $PROFILE profile"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_rmem="$TCP_RMEM"
    fi
}

# Audit TCP Auto-tuning
audit_tcp_autotuning() {
    print_section "TCP Auto-tuning Configuration"
    
    local tcp_moderate_rcvbuf=$(get_sysctl net.ipv4.tcp_moderate_rcvbuf)
    local tcp_window_scaling=$(get_sysctl net.ipv4.tcp_window_scaling)
    local tcp_timestamps=$(get_sysctl net.ipv4.tcp_timestamps)
    
    echo "Current Settings:"
    echo "  tcp_moderate_rcvbuf (auto-tune RX): $tcp_moderate_rcvbuf"
    echo "  tcp_window_scaling (large windows):  $tcp_window_scaling"
    echo "  tcp_timestamps (RTT measurement):    $tcp_timestamps"
    
    if [[ $tcp_moderate_rcvbuf -ne 1 ]]; then
        print_issue "CRITICAL" "TCP receive auto-tuning is DISABLED!"
        echo "  IMPACT: Buffers won't grow dynamically, limiting throughput"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
    else
        print_issue "OK" "TCP auto-tuning is enabled"
    fi
    
    if [[ $tcp_window_scaling -ne 1 ]]; then
        print_issue "CRITICAL" "TCP window scaling is DISABLED - buffers limited to 64KB!"
        echo "  IMPACT: Cannot use buffers > 64KB, severely limiting high-BDP networks"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_window_scaling=1
    else
        print_issue "OK" "TCP window scaling is enabled"
    fi
    
    if [[ $PROFILE == "low-latency" || $PROFILE == "ultra-low-latency" ]]; then
        if [[ $tcp_timestamps -eq 1 ]]; then
            print_issue "INFO" "TCP timestamps enabled (adds 12 bytes overhead per packet)"
            echo "  SUGGESTION: For ultra-low latency, consider disabling (sysctl -w net.ipv4.tcp_timestamps=0)"
        fi
    fi
}

# Audit Connection Queues
audit_connection_queues() {
    print_section "Connection Queue Settings"
    
    local somaxconn=$(get_sysctl net.core.somaxconn)
    local tcp_max_syn_backlog=$(get_sysctl net.ipv4.tcp_max_syn_backlog)
    
    echo "Current Settings:"
    echo "  somaxconn (listen backlog):     $somaxconn"
    echo "  tcp_max_syn_backlog (SYN queue): $tcp_max_syn_backlog"
    
    echo -e "\nRecommended for $PROFILE profile:"
    echo "  somaxconn:           $SOMAXCONN"
    echo "  tcp_max_syn_backlog: $TCP_MAX_SYN_BACKLOG"
    
    if (( somaxconn < SOMAXCONN )); then
        print_issue "WARNING" "somaxconn ($somaxconn) is below recommended ($SOMAXCONN)"
        echo "  IMPACT: Applications calling listen() will be limited, causing connection drops"
        [[ $APPLY_FIX == true ]] && sysctl -w net.core.somaxconn=$SOMAXCONN
    else
        print_issue "OK" "somaxconn is adequate"
    fi
    
    if (( tcp_max_syn_backlog < TCP_MAX_SYN_BACKLOG )); then
        print_issue "WARNING" "tcp_max_syn_backlog ($tcp_max_syn_backlog) is below recommended"
        echo "  IMPACT: SYN flood vulnerability, connection drops under load"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_max_syn_backlog=$TCP_MAX_SYN_BACKLOG
    else
        print_issue "OK" "tcp_max_syn_backlog is adequate"
    fi
}

# Audit Network Device Queues
audit_netdev_queues() {
    print_section "Network Device Queue Settings"
    
    local netdev_max_backlog=$(get_sysctl net.core.netdev_max_backlog)
    local netdev_budget=$(get_sysctl net.core.netdev_budget)
    local netdev_budget_usecs=$(get_sysctl net.core.netdev_budget_usecs)
    
    echo "Current Settings:"
    echo "  netdev_max_backlog (per-CPU queue): $netdev_max_backlog"
    echo "  netdev_budget (packets/softirq):     $netdev_budget"
    
    if [[ $netdev_budget_usecs != "N/A" ]]; then
        echo "  netdev_budget_usecs (time/softirq):  $netdev_budget_usecs μs"
    fi
    
    echo -e "\nRecommended for $PROFILE profile:"
    echo "  netdev_max_backlog: $NETDEV_MAX_BACKLOG"
    
    if (( netdev_max_backlog < NETDEV_MAX_BACKLOG )); then
        print_issue "WARNING" "netdev_max_backlog ($netdev_max_backlog) is below recommended"
        echo "  IMPACT: Packet drops under high packet rate (bursts)"
        [[ $APPLY_FIX == true ]] && sysctl -w net.core.netdev_max_backlog=$NETDEV_MAX_BACKLOG
    else
        print_issue "OK" "netdev_max_backlog is adequate"
    fi
    
    if [[ $PROFILE == "low-latency" || $PROFILE == "ultra-low-latency" ]]; then
        if [[ $netdev_budget != "N/A" ]] && (( netdev_budget > 300 )); then
            print_issue "INFO" "netdev_budget is high for low-latency profile"
            echo "  SUGGESTION: Lower to 150-300 for better latency (at cost of throughput)"
        fi
    fi
}

# Audit Interface Settings
audit_interface_settings() {
    print_section "Network Interface Configuration"
    
    for iface in $INTERFACES; do
        echo -e "\n${BOLD}Interface: $iface${NC}"
        
        # TX queue length
        local txqueuelen=$(ip link show $iface | grep -oP 'qlen \K\d+' || echo "N/A")
        echo "  txqueuelen: $txqueuelen"
        
        if [[ $txqueuelen != "N/A" ]] && (( txqueuelen < TXQUEUELEN )); then
            print_issue "WARNING" "$iface txqueuelen ($txqueuelen) is below recommended ($TXQUEUELEN)"
            [[ $APPLY_FIX == true ]] && ip link set $iface txqueuelen $TXQUEUELEN
        elif [[ $txqueuelen != "N/A" ]]; then
            print_issue "OK" "$iface txqueuelen is adequate"
        fi
        
        # Ring buffers (if ethtool available)
        if command -v ethtool &> /dev/null; then
            local ring_info=$(ethtool -g $iface 2>/dev/null || echo "")
            if [[ -n $ring_info ]]; then
                echo "  Ring Buffers:"
                echo "$ring_info" | grep -A2 "Current hardware settings:" | tail -2
                
                # Extract current RX/TX values
                local rx_current=$(echo "$ring_info" | grep "^RX:" | tail -1 | awk '{print $2}')
                local tx_current=$(echo "$ring_info" | grep "^TX:" | tail -1 | awk '{print $2}')
                local rx_max=$(echo "$ring_info" | grep "^RX:" | head -1 | awk '{print $2}')
                local tx_max=$(echo "$ring_info" | grep "^TX:" | head -1 | awk '{print $2}')
                
                if [[ -n $rx_current && -n $rx_max ]] && (( rx_current < rx_max )); then
                    print_issue "INFO" "$iface RX ring ($rx_current) can be increased to $rx_max"
                    if [[ $APPLY_FIX == true && $PROFILE == "high-bandwidth" ]]; then
                        ethtool -G $iface rx $rx_max 2>/dev/null || true
                    fi
                fi
            fi
        fi
        
        # Qdisc info
        local qdisc=$(tc qdisc show dev $iface 2>/dev/null | head -1 || echo "N/A")
        echo "  Qdisc: $qdisc"
        
        if [[ $PROFILE == "low-latency" || $PROFILE == "ultra-low-latency" ]]; then
            if echo "$qdisc" | grep -q "pfifo_fast"; then
                print_issue "INFO" "$iface using pfifo_fast (consider fq_codel or fq for better latency)"
            fi
        fi
    done
}

# Audit Global TCP Memory
audit_tcp_memory() {
    print_section "Global TCP Memory Limits"
    
    local tcp_mem=$(get_sysctl net.ipv4.tcp_mem)
    IFS=' ' read -r tcp_mem_low tcp_mem_pres tcp_mem_high <<< "$tcp_mem"
    
    echo "Current Settings (in pages):"
    echo "  tcp_mem: $tcp_mem_low $tcp_mem_pres $tcp_mem_high"
    echo "  In bytes:"
    echo "    low:      $(bytes_to_human $(pages_to_bytes $tcp_mem_low))"
    echo "    pressure: $(bytes_to_human $(pages_to_bytes $tcp_mem_pres))"
    echo "    high:     $(bytes_to_human $(pages_to_bytes $tcp_mem_high))"
    
    echo -e "\nRecommended for $PROFILE profile:"
    echo "  tcp_mem: $TCP_MEM_LOW_PAGES $TCP_MEM_PRESSURE_PAGES $TCP_MEM_HIGH_PAGES (pages)"
    echo "  In bytes:"
    echo "    low:      $(bytes_to_human $TCP_MEM_LOW)"
    echo "    pressure: $(bytes_to_human $TCP_MEM_PRESSURE)"
    echo "    high:     $(bytes_to_human $TCP_MEM_HIGH)"
    
    # Check current usage
    local tcp_mem_current=$(awk '/^TCP:/{print $NF}' /proc/net/sockstat 2>/dev/null || echo "0")
    if [[ -n $tcp_mem_current && $tcp_mem_current != "0" ]]; then
        local tcp_mem_current_bytes=$(pages_to_bytes $tcp_mem_current)
        local tcp_mem_high_bytes=$(pages_to_bytes $tcp_mem_high)
        local usage_percent=$(( 100 * tcp_mem_current_bytes / tcp_mem_high_bytes ))
        
        echo -e "\nCurrent Usage:"
        echo "  TCP memory used: $(bytes_to_human $tcp_mem_current_bytes) (${usage_percent}% of high threshold)"
        
        if (( usage_percent > 80 )); then
            print_issue "CRITICAL" "TCP memory usage at ${usage_percent}% of limit!"
            echo "  IMPACT: System is under memory pressure, may drop connections"
        elif (( usage_percent > 50 )); then
            print_issue "WARNING" "TCP memory usage at ${usage_percent}% of limit"
        else
            print_issue "OK" "TCP memory usage is healthy (${usage_percent}%)"
        fi
    fi
    
    if (( tcp_mem_high < TCP_MEM_HIGH_PAGES )); then
        print_issue "WARNING" "tcp_mem high threshold is below recommended"
        [[ $APPLY_FIX == true ]] && sysctl -w net.ipv4.tcp_mem="$TCP_MEM_LOW_PAGES $TCP_MEM_PRESSURE_PAGES $TCP_MEM_HIGH_PAGES"
    fi
}

# Check for common misconfigurations
audit_common_issues() {
    print_section "Common Misconfiguration Checks"
    
    # Check 1: rmem_max >= tcp_rmem[2]
    local rmem_max=$(get_sysctl net.core.rmem_max)
    local tcp_rmem=$(get_sysctl net.ipv4.tcp_rmem)
    IFS=' ' read -r _ _ tcp_rmem_max <<< "$tcp_rmem"
    
    if (( tcp_rmem_max > rmem_max )); then
        print_issue "CRITICAL" "CONSISTENCY ERROR: tcp_rmem[2] ($tcp_rmem_max) > rmem_max ($rmem_max)"
        echo "  EXPLANATION:"
        echo "    - TCP auto-tuning tries to grow buffer up to tcp_rmem[2]"
        echo "    - But rmem_max caps ALL socket buffers (hard limit)"
        echo "    - Result: Buffer can only grow to $rmem_max, wasting tcp_rmem[2] setting"
        echo "  FIX: Set rmem_max >= tcp_rmem[2]"
        echo "    sysctl -w net.core.rmem_max=$tcp_rmem_max"
    else
        local headroom=$(( rmem_max - tcp_rmem_max ))
        print_issue "OK" "rmem_max >= tcp_rmem[2] (headroom: $(bytes_to_human $headroom))"
    fi
    
    # Check 2: wmem_max >= tcp_wmem[2]
    local wmem_max=$(get_sysctl net.core.wmem_max)
    local tcp_wmem=$(get_sysctl net.ipv4.tcp_wmem)
    IFS=' ' read -r _ _ tcp_wmem_max <<< "$tcp_wmem"
    
    if (( tcp_wmem_max > wmem_max )); then
        print_issue "CRITICAL" "CONSISTENCY ERROR: tcp_wmem[2] ($tcp_wmem_max) > wmem_max ($wmem_max)"
        echo "  FIX: sysctl -w net.core.wmem_max=$tcp_wmem_max"
    else
        print_issue "OK" "wmem_max >= tcp_wmem[2]"
    fi
    
    # Check 3: TCP window scaling for large buffers
    local tcp_window_scaling=$(get_sysctl net.ipv4.tcp_window_scaling)
    if (( tcp_rmem_max > 65535 )) && [[ $tcp_window_scaling -ne 1 ]]; then
        print_issue "CRITICAL" "Window scaling DISABLED but tcp_rmem[2] > 64KB!"
        echo "  IMPACT: Large buffers are useless without window scaling"
        echo "  FIX: sysctl -w net.ipv4.tcp_window_scaling=1"
    fi
    
    # Check 4: Orphan socket limits
    local tcp_max_orphans=$(get_sysctl net.ipv4.tcp_max_orphans)
    local recommended_orphans=$((65536 * TOTAL_RAM_GB))
    if (( tcp_max_orphans < recommended_orphans )); then
        print_issue "WARNING" "tcp_max_orphans ($tcp_max_orphans) may be too low for ${TOTAL_RAM_GB}GB RAM"
        echo "  SUGGESTION: sysctl -w net.ipv4.tcp_max_orphans=$recommended_orphans"
    fi
}

# Generate tuning script
generate_tuning_script() {
    local script_file="/tmp/apply_network_tuning.sh"
    
    print_section "Generating Tuning Script"
    
    cat > "$script_file" << 'EOFSCRIPT'
#!/bin/bash
# Auto-generated network tuning script
# Generated by network_buffer_audit.sh
# Profile: PROFILE_PLACEHOLDER
# Date: DATE_PLACEHOLDER

set -euo pipefail

echo "Backing up current sysctl settings..."
sysctl -a 2>/dev/null | grep -E 'net\.(core|ipv4)' > /etc/sysctl.d/00-backup-$(date +%Y%m%d).conf

echo "Applying network tuning for PROFILE_PLACEHOLDER profile..."

# Core socket buffers
sysctl -w net.core.rmem_max=RMEM_MAX_PLACEHOLDER
sysctl -w net.core.wmem_max=WMEM_MAX_PLACEHOLDER
sysctl -w net.core.rmem_default=RMEM_DEFAULT_PLACEHOLDER
sysctl -w net.core.wmem_default=WMEM_DEFAULT_PLACEHOLDER

# TCP buffers
sysctl -w net.ipv4.tcp_rmem="TCP_RMEM_PLACEHOLDER"
sysctl -w net.ipv4.tcp_wmem="TCP_WMEM_PLACEHOLDER"
sysctl -w net.ipv4.tcp_mem="TCP_MEM_PLACEHOLDER"

# TCP features
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

# Connection queues
sysctl -w net.core.somaxconn=SOMAXCONN_PLACEHOLDER
sysctl -w net.ipv4.tcp_max_syn_backlog=TCP_MAX_SYN_BACKLOG_PLACEHOLDER

# Network device queues
sysctl -w net.core.netdev_max_backlog=NETDEV_MAX_BACKLOG_PLACEHOLDER
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.netdev_budget_usecs=8000

# Interface queues
INTERFACES_PLACEHOLDER

echo "Making settings persistent..."
cat > /etc/sysctl.d/99-network-tuning.conf << 'EOF'
# Network tuning for PROFILE_PLACEHOLDER profile
# Generated: DATE_PLACEHOLDER

# Core socket buffers
net.core.rmem_max = RMEM_MAX_PLACEHOLDER
net.core.wmem_max = WMEM_MAX_PLACEHOLDER

# TCP buffers
net.ipv4.tcp_rmem = TCP_RMEM_PLACEHOLDER
net.ipv4.tcp_wmem = TCP_WMEM_PLACEHOLDER
net.ipv4.tcp_mem = TCP_MEM_PLACEHOLDER

# TCP features
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Connection queues
net.core.somaxconn = SOMAXCONN_PLACEHOLDER
net.ipv4.tcp_max_syn_backlog = TCP_MAX_SYN_BACKLOG_PLACEHOLDER

# Network device queues
net.core.netdev_max_backlog = NETDEV_MAX_BACKLOG_PLACEHOLDER
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
EOF

echo "Tuning applied successfully!"
echo "Settings will persist across reboots."
EOFSCRIPT

    # Replace placeholders
    sed -i "s/PROFILE_PLACEHOLDER/$PROFILE/g" "$script_file"
    sed -i "s/DATE_PLACEHOLDER/$(date)/g" "$script_file"
    sed -i "s/RMEM_MAX_PLACEHOLDER/$RMEM_MAX/g" "$script_file"
    sed -i "s/WMEM_MAX_PLACEHOLDER/$WMEM_MAX/g" "$script_file"
    sed -i "s/RMEM_DEFAULT_PLACEHOLDER/$(echo $TCP_RMEM | awk '{print $2}')/g" "$script_file"
    sed -i "s/WMEM_DEFAULT_PLACEHOLDER/$(echo $TCP_WMEM | awk '{print $2}')/g" "$script_file"
    sed -i "s/TCP_RMEM_PLACEHOLDER/$TCP_RMEM/g" "$script_file"
    sed -i "s/TCP_WMEM_PLACEHOLDER/$TCP_WMEM/g" "$script_file"
    sed -i "s/TCP_MEM_PLACEHOLDER/$TCP_MEM_LOW_PAGES $TCP_MEM_PRESSURE_PAGES $TCP_MEM_HIGH_PAGES/g" "$script_file"
    sed -i "s/SOMAXCONN_PLACEHOLDER/$SOMAXCONN/g" "$script_file"
    sed -i "s/TCP_MAX_SYN_BACKLOG_PLACEHOLDER/$TCP_MAX_SYN_BACKLOG/g" "$script_file"
    sed -i "s/NETDEV_MAX_BACKLOG_PLACEHOLDER/$NETDEV_MAX_BACKLOG/g" "$script_file"
    
    # Add interface commands
    local iface_cmds=""
    for iface in $INTERFACES; do
        iface_cmds="${iface_cmds}ip link set $iface txqueuelen $TXQUEUELEN\n"
    done
    sed -i "s|INTERFACES_PLACEHOLDER|echo -e \"$iface_cmds\" | bash|g" "$script_file"
    
    chmod +x "$script_file"
    
    echo "Tuning script generated: $script_file"
    print_issue "INFO" "Review and execute: sudo $script_file"
}

# Main execution
main() {
    print_header "Linux Network Buffer Audit - Profile: $PROFILE"

    # Display permission mode
    if [[ $IS_ROOT -eq 1 ]]; then
        echo -e "${GREEN}✓ Running as root - Full read/write access enabled${NC}"
    else
        echo -e "${YELLOW}⚠  Running as regular user - Read-only mode (analysis only)${NC}"
        echo "   To apply fixes with --fix flag, use: sudo $0 ..."
    fi
    echo ""

    echo "Report will be saved to: $REPORT_FILE"
    echo "Date: $(date)"

    if [[ $APPLY_FIX == true ]]; then
        echo -e "${YELLOW}WARNING: --fix enabled, will apply changes!${NC}"
        echo "Backing up current sysctl settings to: $SYSCTL_BACKUP"
        sysctl -a 2>/dev/null | grep -E 'net\.(core|ipv4)' > "$SYSCTL_BACKUP" || true
        sleep 2
    fi
    
    # CRITICAL: Get system info FIRST before using TOTAL_RAM
    get_system_info
    
    # Now get profile recommendations (uses TOTAL_RAM)
    get_profile_recommendations
    
    # Run all audits
    audit_core_buffers
    audit_tcp_buffers
    audit_tcp_autotuning
    audit_connection_queues
    audit_netdev_queues
    audit_interface_settings
    audit_tcp_memory
    audit_common_issues
    
    # Generate tuning script
    if [[ $APPLY_FIX == false ]]; then
        generate_tuning_script
    fi
    
    # Summary
    print_header "Audit Complete"
    
    echo "Summary:"
    echo "  - Full report: $REPORT_FILE"
    if [[ $APPLY_FIX == true ]]; then
        echo "  - Changes applied in this session"
        echo "  - Backup: $SYSCTL_BACKUP"
        echo "  - To make permanent, run the generated tuning script"
    else
        echo "  - No changes applied (use --fix to apply)"
        echo "  - Generated tuning script: /tmp/apply_network_tuning.sh"
    fi
    
    echo -e "\n${BOLD}Profile-Specific Notes:${NC}"
    case $PROFILE in
        high-bandwidth)
            echo "  ✓ Optimized for 10Gbps+ networks"
            echo "  ✓ Large buffers for bulk data transfer"
            echo "  ✓ May increase latency slightly"
            echo "  ✓ Good for: File servers, CDN, backup systems"
            ;;
        low-latency)
            echo "  ✓ Optimized for <10ms latency"
            echo "  ✓ Smaller buffers to reduce queuing delay"
            echo "  ✓ May reduce throughput on high-BDP links"
            echo "  ✓ Good for: Message delivery, real-time applications"
            ;;
        ultra-low-latency)
            echo "  ✓ Optimized for sub-millisecond latency"
            echo "  ✓ Minimal buffering"
            echo "  ✓ Consider: kernel bypass (DPDK), busy polling"
            echo "  ✓ Good for: Ultra-low-latency message delivery"
            ;;
        balanced)
            echo "  ✓ General purpose high-performance"
            echo "  ✓ Good balance of throughput and latency"
            echo "  ✓ Good for: Web servers, databases, general apps"
            ;;
    esac
    
    echo -e "\n${BOLD}Additional Recommendations:${NC}"
    echo "  1. Monitor with: ss -tm, nstat, sar -n DEV"
    echo "  2. Test with: iperf3, netperf, wrk (HTTP)"
    echo "  3. Adjust based on actual workload metrics"
    echo "  4. Consider: interrupt affinity, CPU governor, NUMA"
    
    if [[ $PROFILE == "low-latency" || $PROFILE == "ultra-low-latency" ]]; then
        echo -e "\n${BOLD}Ultra Low-Latency Additional Steps:${NC}"
        echo "  1. Disable interrupt coalescing: ethtool -C eth0 rx-usecs 0"
        echo "  2. Set CPU governor to performance: cpupower frequency-set -g performance"
        echo "  3. Disable C-states: intel_idle.max_cstate=0"
        echo "  4. Use isolcpus to dedicate CPUs"
        echo "  5. Enable busy polling: sysctl -w net.core.busy_poll=50"
        echo "  6. Consider kernel bypass (DPDK, XDP)"
    fi
}

# Run main
main

exit 0