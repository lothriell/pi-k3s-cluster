# Raspberry Pi CM5 Failure Report — rpi-k3s-1

**Date:** 2026-03-27
**Device:** Raspberry Pi Compute Module 5, 16GB RAM, 32GB eMMC
**Serial / Board ID:** (check label on the CM5 module)
**Purchase date:** (fill in)

## Summary

The CM5 module designated rpi-k3s-1 (10.0.0.11) suffers from recurring hard lockups/crashes. The node becomes completely unresponsive — no SSH, no ICMP ping, no network activity — requiring a physical power cycle to recover. No kernel panic, OOM, or graceful shutdown is logged. The failure occurs regardless of carrier board, PSU, switch port, or ethernet cable.

## Failure Timeline

| # | Date/Time (UTC) | Uptime before crash | Notes |
|---|----------------|---------------------|-------|
| 1 | 2026-03-25 ~17:40 | ~5 months | First observed crash. Ended long uptime since 2025-10-07. |
| 2 | 2026-03-26 ~06:19 | ~9 hours | Crashed overnight. NTP issues observed (Ubuntu NTS, since fixed). |
| 3 | 2026-03-27 ~05:17 | ~15 hours | Crashed overnight. Remote logs confirmed network was OK until death. |
| 4 | 2026-03-27 ~11:21 | ~2.5 hours | Crashed mid-day after carrier board swap to board 4. |
| 5 | 2026-03-27 ~15:42 | ~2.8 hours | Crashed on Waveshare carrier board. Third different board tested. |

**Pattern:** Crashes are becoming more frequent — from months of uptime down to ~2.5 hours. Failure now reproduced on 3 different carrier boards.

## Diagnostic Steps Performed

### 1. Software / OS ruled out
- Ubuntu 25.10 (ARM64), kernel 6.17.0-1008-raspi
- K3s v1.31.4+k3s1 running identical workload as other 3 nodes
- NTP fixed from Ubuntu NTS to pool.ntp.org (not the cause — crashes continued)
- `hung_task_panic=1` and `panic_on_oops=1` set — no kernel panic triggered
- No OOM kills in any logs
- No kernel oops, no error messages preceding any crash

### 2. Network ruled out
- Custom network watchdog service logging every 60 seconds: gateway ping, DNS ping, peer node ping, DNS resolution, link state, NIC speed
- **Last watchdog entry before every crash: all OK, link=1, speed=1000**
- No network degradation before any failure
- Tested on two different switch ports
- Ethernet cable replaced

### 3. Hardware isolation testing
- **Carrier board 1 (original):** Crashes #1, #2, #3
- **Carrier board 4 (swapped):** Crash #4 — same failure
- **Waveshare carrier board:** Crash #5 — same failure. Three different boards, identical behavior.
- **PSU:** Different carrier board = different power path, still crashed
- **Thermal:** All crashes occurred at normal temperatures (45-50°C), no throttling (`throttled=0x0`)

### 4. Remote logging evidence
- All syslog forwarded to rpi-k3s-2 via UDP (rsyslog)
- Remote logs confirm: normal operation → instant silence. No warning, no graceful shutdown, no final kernel message.
- The node stops transmitting any data (including syslog, ICMP responses) instantaneously

### 5. Other 3 nodes are stable
- rpi-k3s-2: 30+ hours uptime, no issues
- rpi-k3s-3: 30+ hours uptime, no issues
- rpi-k3s-4: Stable since last reboot (cable replacement), no issues
- All 4 nodes run identical OS, kernel, K3s version, and similar workloads

## Conclusion

The failure is isolated to this specific CM5 module. All external factors (carrier board, PSU, network, cable, switch port, software) have been eliminated through systematic testing. The instantaneous nature of the failure (no kernel panic, no graceful shutdown, no warning in logs) points to a silicon-level defect — likely a power regulation fault or memory controller issue on the CM5 SoC.

## Environment Details

- **OS:** Ubuntu 25.10 (oracular) ARM64
- **Kernel:** 6.17.0-1008-raspi
- **K3s:** v1.31.4+k3s1
- **Network:** Static IP 10.0.0.11, Gigabit Ethernet, UniFi managed switch
- **Workload:** Kubernetes control plane (K3s server) + monitoring, GitOps containers
- **Cooling:** Passive heatsink, temperatures consistently 45-50°C
- **Power:** USB-C via carrier board, no under-voltage warnings ever recorded

## Requested Action

Replacement of the CM5 module under warranty.
