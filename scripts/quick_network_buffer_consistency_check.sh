#!/bin/bash
# Quick manual consistency check

set -euo pipefail

echo "=== Quick Network Buffer Consistency Check ==="
echo ""

# Helper function to get sysctl value safely
get_sysctl() {
    local param=$1
    local value=$(sysctl -n "$param" 2>/dev/null || echo "")
    # Fallback to /proc/sys if sysctl fails
    if [ -z "$value" ]; then
        local proc_path="/proc/sys/${param//.//}"
        if [ -f "$proc_path" ]; then
            value=$(cat "$proc_path" 2>/dev/null | tr '\n' ' ' | xargs || echo "")
        fi
    fi
    echo "$value"
}

# 1. Get values with error handling
RMEM_MAX=$(get_sysctl net.core.rmem_max)
RMEM_MAX=${RMEM_MAX:-0}
WMEM_MAX=$(get_sysctl net.core.wmem_max)
WMEM_MAX=${WMEM_MAX:-0}
TCP_RMEM=$(get_sysctl net.ipv4.tcp_rmem)
TCP_RMEM=${TCP_RMEM:-"0 0 0"}
TCP_WMEM=$(get_sysctl net.ipv4.tcp_wmem)
TCP_WMEM=${TCP_WMEM:-"0 0 0"}
WINDOW_SCALING=$(get_sysctl net.ipv4.tcp_window_scaling)
WINDOW_SCALING=${WINDOW_SCALING:-0}
AUTO_TUNING=$(get_sysctl net.ipv4.tcp_moderate_rcvbuf)
AUTO_TUNING=${AUTO_TUNING:-0}

# Parse TCP buffer values safely
read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
TCP_RMEM_MIN=${TCP_RMEM_MIN:-0}
TCP_RMEM_DEF=${TCP_RMEM_DEF:-0}
TCP_RMEM_MAX=${TCP_RMEM_MAX:-0}

read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"
TCP_WMEM_MIN=${TCP_WMEM_MIN:-0}
TCP_WMEM_DEF=${TCP_WMEM_DEF:-0}
TCP_WMEM_MAX=${TCP_WMEM_MAX:-0}

# 2. Display - Ensure values are numeric before arithmetic
# Check for empty or invalid values
if [ "$RMEM_MAX" = "0" ] || [ "$WMEM_MAX" = "0" ] || [ "$TCP_RMEM_MAX" = "0" ] || [ "$TCP_WMEM_MAX" = "0" ]; then
    echo "⚠️  WARNING: Some values could not be read. You may need sudo for full access."
    echo "Run: sudo $0"
    echo ""
fi

echo "Current Configuration:"
echo "  rmem_max:     $RMEM_MAX bytes ($(($RMEM_MAX / 1048576 || echo 0))MB)"
echo "  tcp_rmem[2]:  $TCP_RMEM_MAX bytes ($(($TCP_RMEM_MAX / 1048576 || echo 0))MB)"
echo "  wmem_max:     $WMEM_MAX bytes ($(($WMEM_MAX / 1048576 || echo 0))MB)"
echo "  tcp_wmem[2]:  $TCP_WMEM_MAX bytes ($(($TCP_WMEM_MAX / 1048576 || echo 0))MB)"
echo ""

# 3. Critical checks
echo "Critical Checks:"

# Check 1
if (( TCP_RMEM_MAX > RMEM_MAX )); then
    echo "  ❌ FAIL: tcp_rmem[2] ($TCP_RMEM_MAX) > rmem_max ($RMEM_MAX)"
    echo "         Auto-tuning LIMITED to $RMEM_MAX!"
else
    echo "  ✅ PASS: tcp_rmem[2] <= rmem_max"
fi

# Check 2
if (( TCP_WMEM_MAX > WMEM_MAX )); then
    echo "  ❌ FAIL: tcp_wmem[2] ($TCP_WMEM_MAX) > wmem_max ($WMEM_MAX)"
else
    echo "  ✅ PASS: tcp_wmem[2] <= wmem_max"
fi

# Check 3
if (( TCP_RMEM_MAX > 65536 )) && [[ $WINDOW_SCALING -ne 1 ]]; then
    echo "  ❌ FAIL: Window scaling disabled but buffers >64KB!"
else
    echo "  ✅ PASS: Window scaling properly configured"
fi

# Check 4
if [[ $AUTO_TUNING -ne 1 ]]; then
    echo "  ❌ FAIL: Auto-tuning disabled - tcp_rmem[2] won't be used!"
else
    echo "  ✅ PASS: Auto-tuning enabled"
fi

echo ""
echo "Quick check complete. Run full consistency checker for detailed analysis."