#!/bin/bash
# Quick manual consistency check

echo "=== Quick Network Buffer Consistency Check ==="
echo ""

# 1. Get values
RMEM_MAX=$(sysctl -n net.core.rmem_max)
WMEM_MAX=$(sysctl -n net.core.wmem_max)
TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)
TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem)
WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)
AUTO_TUNING=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)

read TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_MAX <<< "$TCP_RMEM"
read TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_MAX <<< "$TCP_WMEM"

# 2. Display
echo "Current Configuration:"
echo "  rmem_max:     $RMEM_MAX bytes ($(($RMEM_MAX / 1048576))MB)"
echo "  tcp_rmem[2]:  $TCP_RMEM_MAX bytes ($(($TCP_RMEM_MAX / 1048576))MB)"
echo "  wmem_max:     $WMEM_MAX bytes ($(($WMEM_MAX / 1048576))MB)"
echo "  tcp_wmem[2]:  $TCP_WMEM_MAX bytes ($(($TCP_WMEM_MAX / 1048576))MB)"
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