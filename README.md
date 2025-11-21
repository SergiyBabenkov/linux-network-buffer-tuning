# Linux Network Buffer Tuning Guide

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/platform-RHEL%208%20%7C%20OEL%208-red)
![Shell](https://img.shields.io/badge/shell-bash-green)

## Overview

Comprehensive guide for tuning Linux network stack buffers (socket, TCP, qdisc, NIC rings) on RHEL/OEL 8. Includes detailed documentation, RTT-based buffer calculations, tuning profiles for low-latency and high-throughput scenarios, and production-ready shell scripts for validation and monitoring.

This repository provides deep technical documentation for optimizing the complete data path from application socket buffers through kernel networking layers to the physical wire.

## Key Features

- **Complete Stack Coverage**: Socket buffers → TCP layer → Queueing disciplines → NIC ring buffers → Wire
- **RTT-Based Calculations**: Scientific approach to buffer sizing using Bandwidth-Delay Product
- **Multiple Tuning Profiles**: Pre-configured settings for message delivery, file transfer, backend, and Internet-facing scenarios
- **Production-Ready Scripts**: Automated audit, consistency checking, and fix application with backup
- **Deep Diagnostics**: Tools and techniques to identify packet drops, buffer overflows, and memory pressure
- **Platform-Specific**: Tested and optimized for RHEL/OEL 8 environments

**Target Environment:** RedHat Enterprise Linux 8 / Oracle Enterprise Linux 8

**Primary Use Cases:**
- **Message Delivery Systems**: Low-latency delivery of small messages (1-5KB) with minimal data loss during network disruptions
- **File Transfer Systems**: High-throughput transfer of large files (MB to GB) with efficient buffer utilization

**Deployment Scenarios:**
- **Backend (Datacenter)**: Systems within same availability zone or datacenter (RTT 0.5-5ms)
- **Customer-facing (Internet)**: Services accepting traffic over the Internet globally (RTT 50-200ms)
- **Cross-region**: Communication between datacenters or regions (RTT 10-100ms)

**Focus:** Optimizing buffer sizing and tuning parameters for specific traffic patterns, minimizing queuing delays and packet loss at every network layer

## Repository Structure

### Core Concepts

1. **[Data Journey Through the Stack](01-data-journey.md)**  
   Traces how a `write()` call transforms into electrical signals on the wire. Covers user space buffers, kernel TCP/IP stack, driver queues, and NIC transmission.

2. **[Hardware and Link Layer Boundaries](02-hardware-link-layer.md)**  
   Explains MTU, MSS, and how frame size impacts latency. Understanding where software ends and hardware begins.

3. **[Socket Buffer Architecture](03-socket-buffer-architecture.md)**  
   Deep dive into `SO_SNDBUF`, `SO_RCVBUF`, TCP window scaling, and how kernel manages memory for a connections.

4. **[System Memory and Kernel Accounting](04-memory-accounting.md)**  
   How Linux tracks network memory usage, the relationship between socket buffers and system memory limits, and when the kernel applies backpressure.

5. **[Queueing and Congestion Control](05-queueing-congestion.md)**  
   Understanding where packets wait, why queues exist, and how TCP congestion control algorithms affect a latency profile.

### Diagnostics and Optimization

6. **[Detecting Memory Pressure and Loss](06-detecting-issues.md)**  
   Tools and techniques to identify when buffers overflow, packets drop, or system memory becomes constrained. Reading `/proc` statistics and netstat output.

7. **[RTT-Based Buffer Sizing](07-rtt-buffer-sizing.md)**  
   Calculating optimal buffer sizes based on actual Round Trip Time measurements and Bandwidth-Delay Product principles.

8. **[System Tuning Profiles](08-low-latency-profile.md)**
   Complete system tuning checklists for RHEL/OEL 8 tailored to message delivery and file transfer use cases, including kernel parameters, interrupt handling, and CPU affinity for network processing.

### Implementation

9. **[Diagnostics and Troubleshooting](09-diagnostics-and-troubleshooting.md)**
   Common configuration inconsistency patterns, detection methods, and troubleshooting procedures for network buffer issues.

10. **[Monitoring and Maintenance](10-monitoring-maintenance.md)**  
    Setting up ongoing instrumentation to track network health, detect degradation, and maintain optimal performance.

11. **[Practical Shell Scripts and Recipes](11-shell-scripts-recipes.md)**  
    Production-ready bash scripts for system auditing, buffer calculation, network monitoring, and automated validation procedures.

## Quick Start

For readers who want to jump straight to implementation:

1. Read [Data Journey Through the Stack](01-data-journey.md) to build a mental model
2. Review [Socket Buffer Architecture](03-socket-buffer-architecture.md) to understand what you're tuning
3. Review [RTT-Based Buffer Sizing](07-rtt-buffer-sizing.md) to understand buffer sizing methodology for your traffic profile
4. Jump to [System Tuning Profiles](08-low-latency-profile.md) for concrete tuning parameters
5. Run the system audit script from [Shell Scripts and Recipes](11-shell-scripts-recipes.md) to baseline your current configuration
6. Follow [Diagnostics and Troubleshooting](09-diagnostics-and-troubleshooting.md) to identify and fix any issues

## Learning Approach

Each section builds on previous concepts, but readers can jump directly to topics of interest. Cross-references link related concepts throughout the documentation.

---

**Start here:** [Data Journey Through the Stack](01-data-journey.md)
