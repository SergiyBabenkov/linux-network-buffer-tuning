# Hardware and Link-Layer Boundaries

## Overview

The physical network imposes hard constraints on packet sizes through the Maximum Transmission Unit (MTU). These constraints directly influence TCP's Maximum Segment Size (MSS), which determines how application data gets chunked for transmission. Understanding this relationship is critical for optimizing both latency and throughput, where serialization delay and packet overhead directly impact performance.

This document explains MTU and MSS in depth, their relationship, how they're established, and how to validate them on RHEL/OEL 8 systems.

## MTU (Maximum Transmission Unit)

### Definition

**MTU (Maximum Transmission Unit)** is the largest packet size a network interface can transmit without fragmentation. On typical Ethernet networks this limit is **1,500 bytes**, a legacy value chosen to balance NIC memory cost and medium-access latency. 

Modern networks support larger "jumbo frames" up to about 9,000 bytes, which improve throughput and can reduce latency by lowering packet overhead. However, fragmented paths, older hardware, and firewalls that block essential ICMP "can't fragment" messages often force systems to remain at the 1,500-byte default.

### Ethernet Frame Structure

```
┌─────────────────────────────────────────────────────────────────┐
│ ETHERNET FRAME (1518 bytes total)                               │
│ ┌──────┬──────┬──────┬──────────────────────────┬──────┐        │
│ │ Dst  │ Src  │ Type │    PAYLOAD (MTU)         │ FCS  │        │
│ │ MAC  │ MAC  │      │    1500 bytes max        │      │        │
│ │ 6 B  │ 6 B  │ 2 B  │                          │ 4 B  │        │
│ └──────┴──────┴──────┴──────────────────────────┴──────┘        │
│                         ▲                                       │
│                         └─ MTU = 1500 bytes                     │
│                            (Maximum payload in frame)           │
│                                                                 │
│ Within MTU (1500 bytes):                                        │
│ ┌──────────────┬────────────┬─────────────────────────┐         │
│ │ IP Header    │ TCP Header │ Application Data        │         │
│ │ 20 bytes min │ 20 bytes   │ 1500-40=1460 bytes max  │         │
│ └──────────────┴────────────┴─────────────────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

**Key Points**:
- The MTU is the payload capacity of the Ethernet frame
- It does NOT include the Ethernet header (14 bytes) or Frame Check Sequence (4 bytes)
- Total wire size for a 1500-byte MTU packet is actually 1518 bytes
- This 1500-byte limit has been standard since the 1980s

### Standard MTU Values

```
Network Type              MTU (bytes)    Notes
────────────────────────────────────────────────────────────────
Ethernet (IEEE 802.3)     1,500         Standard, universal compatibility
Jumbo Frames              9,000         Requires end-to-end support
Wi-Fi (802.11)            2,304         Theoretical max, often lower
PPPoE (DSL)               1,492         8 bytes lost to PPPoE header
VPN tunnels               1,400-1,450   Reduced by encryption overhead
Loopback                  65,536        Local only, no physical limit
GRE tunnel                1,476         24 bytes for GRE header
VXLAN                     1,450         50 bytes for VXLAN encapsulation
```

### When MTU is Established

MTU is determined at different stages of network configuration and connection establishment:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. NETWORK INTERFACE CONFIGURATION (Static)                     │
│    - Set when interface is brought up                           │
│    - Default: 1500 for Ethernet                                 │
│    - Command: ip link set eth0 mtu 1500                         │
│    - Persists until changed or interface restart                │
└─────────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. PATH MTU DISCOVERY (Dynamic - Per Connection)                │
│    - Happens during TCP connection lifetime                     │
│    - Finds minimum MTU along entire path                        │
│    - Uses DF (Don't Fragment) flag + ICMP                       │
│                                                                 │
│    Timeline:                                                    │
│    T=0:    SYN sent with DF flag, size based on local MTU       │
│    T=RTT:  If ICMP "Fragmentation Needed" received              │
│            → Reduce MTU, retry                                  │
│    T=2RTT: Eventually finds Path MTU                            │
│            → Stored per-route in kernel routing cache           │
└─────────────────────────────────────────────────────────────────┘
```

**Static Configuration**: The interface MTU is a configuration parameter set by the system administrator or DHCP. This value tells the kernel the maximum packet size the local network interface can handle.

**Dynamic Discovery**: Path MTU Discovery (PMTUD) is a TCP feature that discovers the minimum MTU across all hops in the network path. This is necessary because different network segments may have different MTUs (e.g., Ethernet at one hop, PPPoE at another).

### Path MTU Discovery (PMTUD)

The process works as follows:

```
Sender                    Router                   Receiver
  │                         │                         │
  │ Packet (1500 bytes)     │                         │
  │ DF flag set             │                         │
  ├────────────────────────►│                         │
  │                         │ MTU = 1492              │
  │                         │ (Can't forward!)        │
  │                         │                         │
  │ ICMP Type 3, Code 4     │                         │
  │ "Frag Needed, DF set"   │                         │
  │ Next-hop MTU: 1492      │                         │
  │◄────────────────────────┤                         │
  │                         │                         │
  │ Packet (1492 bytes)     │                         │
  │ DF flag set             │                         │
  ├────────────────────────►├────────────────────────►│
  │                         │                         │
  │                         │      Success!           │
```

**Critical Point**: PMTUD relies on ICMP "Fragmentation Needed" messages. Many firewalls block these messages, causing PMTUD to fail. This results in "black hole" scenarios where packets are silently dropped, leading to connection hangs and timeouts.

### Checking Interface MTU

**Method 1: ip command (modern)**

```bash
# Detect default interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
echo "Default interface: $DEFAULT_IF"

# Show interface details
ip link show $DEFAULT_IF

# Output example:
# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
#                                             ^^^^^^^^
#                                             Current MTU

# List all interfaces with MTU
ip -o link show | awk -F': ' '{print $2}' | grep -v lo | while read iface; do
    echo "$iface: $(cat /sys/class/net/$iface/mtu 2>/dev/null || echo 'N/A')"
done
```

**Method 2: sysfs (direct kernel query)**

```bash
# Detect default interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

# Read MTU directly from kernel
cat /sys/class/net/$DEFAULT_IF/mtu

# Output:
# 1500
```

**Method 3: ifconfig (legacy, may not be installed)**

```bash
# Detect default interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

ifconfig $DEFAULT_IF | grep MTU

# Output:
# xxx0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
```

### Checking Path MTU for Active Connections

```bash
# View Path MTU for active connection to specific destination
ss -ti dst 10.0.0.5 | grep mtu

# Output:
# pmtu:1500 rcvmss:1460 advmss:1460
# ^^^^^^^^
# Current Path MTU discovered for this connection

# Alternative: Use ip route get to see cached PMTU
ip route get 10.0.0.5

# Output:
# 10.0.0.5 via 192.168.1.1 dev eth0 src 192.168.1.10 uid 1000 
#     cache expires 593sec mtu 1500
#                          ^^^^^^^^
#                          Path MTU cached by kernel
```

### Testing Path MTU with ping

```bash
# Test maximum packet size that can traverse path without fragmentation
# -M do: Set DF (Don't Fragment) flag
# -s: Packet size (add 28 for IP+ICMP headers to get total)

# Test standard MTU (1472 + 28 = 1500 total)
ping -M do -s 1472 -c 3 10.0.0.5

# If this works, MTU is at least 1500
# If this fails with "Frag needed", path MTU is smaller

# Binary search for actual path MTU
ping -M do -s 1400 -c 3 10.0.0.5   # Try smaller
ping -M do -s 1450 -c 3 10.0.0.5   # Try middle
# Continue until you find the maximum that works
```

## MSS (Maximum Segment Size)

### Definition

**MSS (Maximum Segment Size)** is the largest block of TCP payload data a host is willing to receive in a single TCP segment. Each endpoint announces its MSS during the TCP handshake, and the peer must never send segments larger than that limit.

**Key characteristics**:
- MSS excludes TCP and IP headers (only counts application data)
- Typically **1460 bytes** for IPv4 on a 1500-byte MTU network
- Defaults to **536 bytes** if not explicitly announced during handshake
- Is a one-way limit, not a negotiation (each side announces independently)
- Ensures segments fit within the path MTU without fragmentation

### TCP Segment Structure

```
┌─────────────────────────────────────────────────────────────────┐
│ TCP SEGMENT ANATOMY                                             │
│                                                                 │
│ ┌───────────────────────────────────────────────────────┐       │
│ │ TCP Segment                                           │       │
│ │ ┌─────────────────┬───────────────────────────────┐   │       │
│ │ │ TCP Header      │ Payload (MSS)                 │   │       │
│ │ │                 │                               │   │       │
│ │ │ 20-60 bytes     │ 1460 bytes (typical)          │   │       │
│ │ │                 │                               │   │       │
│ │ │ Fields:         │ ◄─── THIS IS MSS ─────────────┤   │       │
│ │ │ - Src port      │                               │   │       │
│ │ │ - Dst port      │ Application data ONLY         │   │       │
│ │ │ - Seq num       │ No headers counted            │   │       │
│ │ │ - Ack num       │                               │   │       │
│ │ │ - Flags         │                               │   │       │
│ │ │ - Window        │                               │   │       │
│ │ │ - Checksum      │                               │   │       │
│ │ │ - Options       │                               │   │       │
│ │ │   (MSS, etc.)   │                               │   │       │
│ │ └─────────────────┴───────────────────────────────┘   │       │
│ └───────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

### When MSS is Established

MSS is negotiated during the **TCP three-way handshake** as a TCP option:

```
┌─────────────────────────────────────────────────────────────────┐
│ TCP THREE-WAY HANDSHAKE WITH MSS NEGOTIATION                    │
│                                                                 │
│ Client                                              Server      │
│   │                                                    │        │
│   │ SYN (seq=100)                                      │        │
│   │ ┌─────────────────────────────────────┐            │        │
│   │ │ TCP Options:                        │            │        │
│   │ │  - MSS: 1460 (client's max)         │            │        │
│   │ │  - Window Scale: 7                  │            │        │
│   │ │  - Timestamps: enabled              │            │        │
│   │ └─────────────────────────────────────┘            │        │
│   ├──────────────────────────────────────────────────► │        │
│   │                                                    │        │
│   │                    SYN-ACK (seq=500, ack=101)      │        │
│   │          ┌─────────────────────────────────────┐   │        │
│   │          │ TCP Options:                        │   │        │
│   │          │  - MSS: 1460 (server's max)         │   │        │
│   │          │  - Window Scale: 7                  │   │        │
│   │          │  - Timestamps: enabled              │   │        │
│   │          └─────────────────────────────────────┘   │        │
│   │◄─────────────────────────────────────────-─────────┤        │
│   │                                                    │        │
│   │ ACK (seq=101, ack=501)                             │        │
│   ├──────────────────────────────────────────────────► │        │
│   │                                                    │        │
│   │ ┌────────────────────────────────────┐             │        │
│   │ │ Effective MSS = min(1460, 1460)    │             │        │
│   │ │             = 1460 bytes           │             │        │
│   │ └────────────────────────────────────┘             │        │
│   │                                                    │        │
│   │ All subsequent segments use MSS=1460               │        │
│   │                                                    │        │
└─────────────────────────────────────────────────────────────────┘
```

### MSS Negotiation Rules

```
1. Each side announces its receive MSS (what it can receive)
   - This is the MSS value in the TCP option
   - Tells the peer: "Don't send me segments larger than this"

2. Sending side uses minimum of:
   - Own interface MTU - 40 (IP+TCP headers)
   - Peer's announced MSS
   - Path MTU - 40 (if PMTU discovery active)

3. MSS is UNIDIRECTIONAL
   - Client → Server MSS may differ from Server → Client MSS
   - Rare in practice (usually symmetric)
   - Each direction is independent

4. Default MSS if not announced: 536 bytes (RFC 879)
   - Ensures compatibility with minimum IPv4 MTU (576 bytes)
   - 576 - 20 (IP) - 20 (TCP) = 536 bytes
   - Very conservative, used only for compatibility
```

### Checking MSS for Active Connections

**Method 1: ss (socket statistics) - Most reliable**

```bash
# Show all TCP connections with detailed info
ss -ti

# Filter by specific destination
ss -ti dst 10.0.0.5

# Output example:
# ESTAB   0   0   192.168.1.10:45678   10.0.0.5:80
#         cubic wscale:7,7 rto:204 rtt:1.5/0.75 ato:40 mss:1448 pmtu:1500
#                                                      ^^^^^^^^  ^^^^^^^^^
#                                                      MSS       Path MTU

# Explanation of output:
# - mss:1448   = Current effective MSS (1500 - 20 - 32 with timestamps)
# - pmtu:1500  = Path MTU discovered for this route
# - wscale:7,7 = Window scaling factor (both directions)
# - rtt:1.5    = Smoothed round-trip time in milliseconds
# - rto:204    = Retransmission timeout in milliseconds
# - cubic      = Congestion control algorithm in use
```

**Method 2: tcpdump - Capture handshake**

```bash
# Capture TCP SYN packets with verbose output
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
tcpdump -i $DEFAULT_IF -nn 'tcp[tcpflags] & tcp-syn != 0' -v

# Output during handshake:
# 12:34:56.789 IP 192.168.1.10.45678 > 10.0.0.5.80: Flags [S], seq 123456,
#   options [mss 1460,nop,wscale 7,nop,nop,TS val 123 ecr 0], length 0
#            ^^^^^^^^
#            Announced MSS

# More focused: capture only MSS option
tcpdump -i $DEFAULT_IF -nn 'tcp[tcpflags] & tcp-syn != 0' -v 2>&1 | grep -E "(mss|MSS)"
```

**Method 3: netstat with extended info (legacy)**

```bash
# On older systems
netstat -tn | head -2    # Show header and one connection
cat /proc/net/tcp        # Raw kernel data (harder to parse)
```

## MTU and MSS Relationship

### The Formula

MSS is not chosen arbitrarily; it is calculated from the MTU so that each TCP segment, once wrapped in its TCP and IP headers, fits entirely within a single link-layer frame on the path.

```
┌─────────────────────────────────────────────────────────────────┐
│ MTU vs MSS Relationship                                         │
│                                                                 │
│ MTU (Layer 2/3 concept)                                         │
│ ┌─────────────────────────────────────────────────────────┐     │
│ │ Ethernet Frame (1518 bytes)                             │     │
│ │ ┌──────────────────────────────────────────────────┐    │     │
│ │ │ IP Datagram (MTU = 1500 bytes)                   │    │     │
│ │ │ ┌──────────────────────────────────────────┐     │    │     │
│ │ │ │ TCP Segment                              │     │    │     │
│ │ │ │ ┌─────────┬──────────────────────┐       │     │    │     │
│ │ │ │ │TCP Hdr  │ MSS (1460 bytes)     │       │     │    │     │
│ │ │ │ │20 bytes │                      │       │     │    │     │
│ │ │ │ └─────────┴──────────────────────┘       │     │    │     │
│ │ │ │ IP Hdr: 20 bytes                         │     │    │     │
│ │ │ └──────────────────────────────────────────┘     │    │     │
│ │ │ Eth Hdr: 14 bytes                   FCS: 4 bytes │    │     │
│ │ └──────────────────────────────────────────────────┘    │     │
│ └─────────────────────────────────────────────────────────┘     │
│                                                                 │
│ Formula:                                                        │
│   MSS = MTU - IP_Header - TCP_Header                            │
│                                                                 │
│   MSS = 1500 - 20 - 20 = 1460 bytes (IPv4, no options)          │
│   MSS = 1500 - 40 - 20 = 1440 bytes (IPv6, no options)          │
│   MSS = 1500 - 20 - 32 = 1448 bytes (IPv4, with TCP timestamps) │
└─────────────────────────────────────────────────────────────────┘
```

### Why This Matters

The MTU defines the upper limit of the full IP packet size, so MSS is derived by subtracting header overhead from that MTU. This dependence ensures TCP never hands IP a segment that would exceed the path MTU, avoiding fragmentation and maintaining predictable latency.

**Fragmentation is the enemy of low latency** because:
1. Reassembly requires buffering all fragments before delivery
2. If any fragment is lost, the entire packet must be retransmitted
3. Fragments often follow different paths, arriving out of order
4. Many middleboxes drop fragments as a security measure

### Common MSS Values

```
MTU (bytes)    IP Ver    TCP Options    MSS (bytes)    Use Case
─────────────────────────────────────────────────────────────────
1500           IPv4      None           1460           Standard Ethernet
1500           IPv4      Timestamps     1448           Standard with timestamps
1500           IPv6      None           1440           IPv6 has larger header
9000           IPv4      None           8960           Jumbo frames
1492           IPv4      None           1452           PPPoE (DSL)
1450           IPv4      None           1410           VPN tunnels
1280           IPv6      None           1220           IPv6 minimum MTU
```

**TCP Timestamps**: When TCP timestamps are enabled (common for congestion control and RTT measurement), the TCP header grows from 20 to 32 bytes, reducing MSS from 1460 to 1448 bytes.

### Key Relationships

```
1. MTU is negotiated at INTERFACE/PATH level
   - Set once per interface or discovered per route
   - Changes rarely (only with network topology changes)

2. MSS is negotiated at TCP CONNECTION level
   - Set once per connection during handshake
   - Cannot be changed after handshake completes

3. MSS is always DERIVED from MTU
   - MSS < MTU (headers consume space)
   - Automatic adjustment through PMTUD

4. Both affect latency differently:
   MTU: Physical serialization delay
   MSS: Number of segments (packet processing overhead)
```

## Impact on Latency

### Serialization Delay

The time to physically transmit a packet on the wire depends on its size and link speed:

```
Serialization_Time = Packet_Size_Bits / Link_Speed_bps

At 1 Gbps:
  1500 bytes = 12,000 bits / 1,000,000,000 bps = 12 microseconds
  9000 bytes = 72,000 bits / 1,000,000,000 bps = 72 microseconds

At 10 Gbps:
  1500 bytes = 12,000 bits / 10,000,000,000 bps = 1.2 microseconds
  9000 bytes = 72,000 bits / 10,000,000,000 bps = 7.2 microseconds
```

**Serialization delay impact**:
- Single 1500-byte packet: 12 µs (negligible)
- But if sending 100KB of data at 1 Gbps: ~800 µs
- This is still small compared to network propagation delays (typically 1-2 ms in datacenters)

### Packet Rate and CPU Overhead

More important than serialization delay is the number of packets processed:

```
Sending 100KB with different MSS values:

MSS 1460 bytes:
  100,000 / 1460 = 69 packets
  69 × (interrupt + processing overhead) = significant CPU

MSS 8960 bytes (jumbo frames):
  100,000 / 8960 = 12 packets
  12 × (interrupt + processing overhead) = lower CPU

Each packet involves:
  - NIC interrupt (or polling check)
  - DMA transfer
  - TCP/IP processing
  - Context switches
```

### Choosing MTU/MSS for Low Latency

```
For Low-Latency Applications:

Standard MTU 1500 → MSS 1460:
├─ ACCEPTABLE for most scenarios
├─ Universal compatibility
├─ No fragmentation risk
└─ Well-tested, predictable behavior

Jumbo Frames 9000 → MSS 8960:
├─ REDUCES packet rate
│  └─ Fewer packets = fewer interrupts = lower CPU overhead
│  └─ BUT: Larger serialization delay (72µs vs 12µs at 1Gbps)
├─ REQUIRES end-to-end support
│  └─ All switches, routers, NICs must support jumbo frames
│  └─ Single non-jumbo hop causes fragmentation or drops
└─ Choose based on message size distribution

Recommendation:
├─ If messages are typically < 1460 bytes: Standard MTU
├─ If bulk transfers are common: Consider jumbo frames
└─ ALWAYS test with actual production traffic patterns
```

## MTU Configuration on RHEL/OEL 8

### Temporarily Change MTU

```bash
# Change MTU for eth0 (active immediately, lost on reboot)
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
sudo ip link set $DEFAULT_IF mtu 9000

# Verify
ip link show $DEFAULT_IF | grep mtu
```

### Permanently Change MTU

**For NetworkManager (RHEL/OEL 8 default)**:

```bash
# Method 1: nmcli command
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
sudo nmcli connection modify $DEFAULT_IF ethernet.mtu 9000
sudo nmcli connection down $DEFAULT_IF
sudo nmcli connection up $DEFAULT_IF

# Method 2: Edit configuration file
sudo vi /etc/sysconfig/network-scripts/ifcfg-eth0

# Add or modify:
# MTU=9000

# Restart network
sudo systemctl restart NetworkManager
```

**For static configuration**:

```bash
# Edit /etc/sysconfig/network-scripts/ifcfg-eth0
sudo vi /etc/sysconfig/network-scripts/ifcfg-eth0

# Add:
MTU=9000

# Restart interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
sudo ifdown $DEFAULT_IF && sudo ifup $DEFAULT_IF
```

### Verify MTU Settings Across Path

```bash
#!/bin/bash
# Script to test path MTU to remote host

REMOTE_HOST="10.0.0.5"
MAX_MTU=1500
MIN_MTU=1280

echo "Testing Path MTU to $REMOTE_HOST"

for size in $(seq $MAX_MTU -50 $MIN_MTU); do
    # Subtract 28 for ICMP/IP headers
    ping_size=$((size - 28))
    
    if ping -M do -s $ping_size -c 1 -W 1 $REMOTE_HOST &>/dev/null; then
        echo "✓ MTU $size works"
        break
    else
        echo "✗ MTU $size failed"
    fi
done
```

## Troubleshooting MTU/MSS Issues

### Common Problems

**Problem 1: Connection hangs after handshake completes**

Symptom: TCP connection established, but data transfer fails
Cause: PMTUD blackhole - ICMP blocked by firewall

```bash
# Check if PMTU discovery is enabled (should be)
cat /proc/sys/net/ipv4/ip_no_pmtu_disc
# Output: 0 (enabled) or 1 (disabled)

# Workaround: Reduce MSS using TCP_MAXSEG socket option
# Or: Use MSS clamping on router (see next section)
```

**Problem 2: Performance degradation with VPN/tunnel**

Symptom: Slow performance over VPN
Cause: MTU too large, causing fragmentation inside tunnel

```bash
# Check route MTU
ip route get <vpn_destination>

# Common fix: Reduce MTU on VPN interface
sudo ip link set tun0 mtu 1400
```

**Problem 3: Jumbo frames partially configured**

Symptom: Intermittent connectivity issues
Cause: Some devices support jumbo frames, others don't

```bash
# Test path with large packets
ping -M do -s 8972 -c 5 <destination>

# If fails, check each hop's MTU capability
```

### MSS Clamping

For networks where PMTUD fails, MSS clamping can force TCP to use smaller segments:

```bash
# Using iptables to clamp MSS to 1400 bytes
sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss 1400

# Verify rule
sudo iptables -t mangle -L -n -v
```

This modifies the MSS option in the TCP SYN packet, forcing both sides to use a smaller MSS.

## Key Takeaways

1. **MTU is a layer 2/3 concept**: Maximum packet size the physical network can handle
   - Standard Ethernet: 1500 bytes
   - Set per interface, discovered per path

2. **MSS is a layer 4 concept**: Maximum TCP payload per segment
   - Typically 1460 bytes (1500 - 40 for headers)
   - Negotiated per TCP connection during handshake

3. **MSS derives from MTU**: MSS = MTU - IP_header - TCP_header
   - Ensures segments fit in frames without fragmentation
   - Fragmentation kills latency and reliability

4. **PMTUD is critical**: Discovers minimum MTU across path
   - Requires ICMP messages
   - Often broken by firewalls
   - Use MSS clamping as workaround

5. **Jumbo frames trade-offs**: 
   - Lower packet rate = lower CPU overhead
   - Higher serialization delay per packet
   - Requires end-to-end support
   - Test thoroughly before deploying

6. **For most applications**: Standard MTU 1500 is usually the right choice
   - Universal compatibility (especially for Internet-facing services)
   - Predictable behavior
   - Well-understood latency characteristics
   - Use jumbo frames only in controlled datacenter environments

## What's Next

Now that hardware and link-layer constraints are understood, the next document explores how the kernel manages memory for socket buffers:

- **[Socket Buffer Architecture](03-socket-buffer-architecture.md)**: Deep dive into SO_SNDBUF/SO_RCVBUF
- **[System Memory and Kernel Accounting](04-memory-accounting.md)**: How Linux tracks network memory
- **[Queueing and Congestion Control](05-queueing-congestion.md)**: Managing packet queues for low latency

---

**Previous**: [The Journey of Data: From Application to the Wire](01-data-journey.md)  
**Next**: [Socket Buffer Architecture](03-socket-buffer-architecture.md)
