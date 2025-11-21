
# Common Inconsistency Patterns

## Pattern 1: "The Inverted Pyramid"

**Symptom:**
```bash
tcp_rmem = "4096 87380 16777216"     # 16MB max
rmem_max = 212992                    # 208KB
```

**Problem:**
- TCP tries to grow to 16MB
- Capped at 208KB by rmem_max
- Actual maximum is 93.75x smaller than intended!

**Visual:**
```
Intended:          |████████████████| 16MB
Actual:  |█|                          208KB
         └─────────────────────────────── Wasted capacity
```
**Detection:**
```bash
TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
RMEM_MAX=$(sysctl -n net.core.rmem_max)

if (( TCP_RMEM_MAX > RMEM_MAX )); then
    echo "INVERTED PYRAMID DETECTED!"
    echo "Effective maximum: $RMEM_MAX (not $TCP_RMEM_MAX)"
fi
```
**Fix:**
```bash
sysctl -w net.core.rmem_max=16777216
```

## Pattern 2: "The Disabled Giant"

**Symptom:**
```bash
tcp_rmem = "4096 87380 8388608"      # 8MB max
rmem_max = 16777216                  # 16MB (good!)
tcp_window_scaling = 0               # DISABLED!
```

**Problem:**
- Buffers configured for 8MB
- Window scaling disabled
- TCP window field is 16-bit = 65,535 bytes maximum
- Effective buffer: 64KB (not 8MB!)

**Visual:**
```
Configured: |████████| 8MB
Window:     |
Usable:     |64KB
            └──── 99.2% wasted!
```
**Detection:**
```bash
TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)

if (( TCP_RMEM_MAX > 65536 )) && [[ $WINDOW_SCALING -ne 1 ]]; then
    echo "DISABLED GIANT DETECTED!"
    echo "Large buffers configured but window scaling disabled"
    echo "Effective maximum: 64KB (not $(( TCP_RMEM_MAX / 1048576 ))MB)"
fi
```
**Fix:**
```bash
sysctl -w net.ipv4.tcp_window_scaling=1
```

## Pattern 3: "The Frozen Pool"

**Symptom:**
```bash
tcp_rmem = "4096 87380 6291456"     # 6MB max
tcp_moderate_rcvbuf = 0              # Auto-tuning DISABLED
```

**Problem:**
- All connections stuck at 87,380 bytes (default)
- tcp_rmem[2] (6MB) never used
- No dynamic adaptation to network conditions

**Visual:**
```
Available: [min=4KB] [default=85KB] [max=6MB]
                          ↑
                     Stuck here forever!
```
**Detection:**
```bash
AUTO_TUNING=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)

if [[ $AUTO_TUNING -ne 1 ]]; then
    TCP_RMEM_DEF=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $2}')
    echo "FROZEN POOL DETECTED!"
    echo "All connections stuck at $TCP_RMEM_DEF bytes"
fi
```
**Fix:**
```bash
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
```

## Pattern 4: "The Overcrowded Pool"

**Symptom:**
```bash
tcp_mem = "88560 118080 177120"     # 177,120 pages = ~690MB total
tcp_rmem = "4096 87380 67108864"    # 64MB per connection
# With 20 connections at max: 20 × 64MB = 1,280MB
# Global limit: 690MB
# Deficit: 590MB!
```

**Problem:**
- Per-connection limits exceed global capacity
- System enters memory pressure early
- Connections throttled or dropped

**Visual:**
```
Global Limit:  |████████| 690MB
20 Connections:|██████████████████| 1,280MB
Overflow:           ^^^^^^ 590MB - DROPS/PRESSURE!
```
**Detection:**
```bash
PAGE_SIZE=$(getconf PAGESIZE)
TCP_MEM_HIGH=$(sysctl -n net.ipv4.tcp_mem | awk '{print $3}')
TCP_MEM_HIGH_BYTES=$(( TCP_MEM_HIGH * PAGE_SIZE ))

TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')
PER_CONN=$(( TCP_RMEM_MAX + TCP_WMEM_MAX ))

MAX_CONNS=$(( TCP_MEM_HIGH_BYTES / PER_CONN ))

echo "Maximum connections at full buffers: $MAX_CONNS"

if (( MAX_CONNS < 100 )); then
    echo "OVERCROWDED POOL DETECTED!"
    echo "Global tcp_mem too low for per-connection buffer sizes"
fi
```
**Fix:**
```bash
# Option 1: Increase global limit
TOTAL_RAM=$(free -b | awk '/^Mem:/{print $2}')
NEW_TCP_MEM_HIGH=$(( TOTAL_RAM / 8 / PAGE_SIZE ))  # 12.5% of RAM
sysctl -w net.ipv4.tcp_mem="... ... $NEW_TCP_MEM_HIGH"

# Option 2: Reduce per-connection buffers
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"  # Reduce max to 16MB
```

## Pattern 5: "The Mismatched Twins"

**Symptom:**
```bash
net.core.rmem_default = 8388608      # 8MB
net.ipv4.tcp_rmem = "4096 131072 6291456"  # Default: 128KB
```

**Problem:**
- `rmem_default` affects UDP/RAW sockets
- `tcp_rmem[1]` affects TCP sockets
- Different defaults create confusion
- UDP gets 8MB, TCP gets 128KB!

**Visual:**
```
UDP socket:  |████████| 8MB (rmem_default)
TCP socket:  |█| 128KB (tcp_rmem[1])
             └── Inconsistent!
```
**Detection:**
```bash
RMEM_DEFAULT=$(sysctl -n net.core.rmem_default)
TCP_RMEM_DEF=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $2}')

if (( RMEM_DEFAULT != TCP_RMEM_DEF )); then
    echo "MISMATCHED TWINS DETECTED!"
    echo "UDP default: $RMEM_DEFAULT"
    echo "TCP default: $TCP_RMEM_DEF"
    echo "This may be intentional, but verify it matches your needs"
fi
```
**Fix (if unintentional):**
```bash
# Align them
sysctl -w net.core.rmem_default=131072
```