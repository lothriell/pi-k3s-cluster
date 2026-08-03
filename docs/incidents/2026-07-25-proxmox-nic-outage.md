# INCIDENT — Proxmox host stuck at boot after planned kernel-activation reboot — OPEN

**Opened:** 2026-07-25 (planned window, task #68)
**Impact start:** VM shutdowns ~16:0x +0200; host reboot issued immediately after.
**Status:** host dark on all paths (tailnet + both remote-site VLANs; only UCG gateways
answer) 25+ min post-reboot. No OOB management at remote site; physical visit required
(user en route once home). Persistent recovery monitor armed.

## Impact
- Planned: authentik, vaultwarden, trivy, forgejo down ~10–15 min.
- **Actual: 11/13 Longhorn volumes faulted** — gitea, forgejo, vaultwarden×2, authentik-pg,
  trivy, prometheus, loki, open-webui, eve prod+test data. Cause of the amplification:
  **replica-placement regression** (see below). Still up: home site, control plane,
  grafana + alertmanager (replicas happened to be off the x86 pair), dev-eve (Docker on
  minisforum), ollama, Pi-hole/ntfy. Bitwarden clients serve cached vaults offline.
- Expect athena watchdog "monitoring DOWN" pages (Prometheus volume faulted) — correct.

## Root causes (two independent)
1. **Replica concentration:** during the 2026-07-24 minisforum 5.5 h outage, Longhorn
   replica-replenishment rebuilt ALL of minisforum's replicas onto the only schedulable
   targets — the x86 pair (etcd Pis excluded by design, rpi-4 near-full). When minisforum
   returned, surplus copies were pruned → most volumes silently ended with BOTH replicas
   on k3s-x86-1 + k3s-x86-2. Post-outage check verified *health* but not *placement*.
   Today's both-x86 window therefore faulted nearly everything stateful.
2. **Host didn't survive the reboot** (root cause TBD on-site: GRUB pause / BIOS post-event
   nag / new-kernel issue. Recovery: boot previous kernel 6.8.12-20-pve from GRUB
   Advanced options if the new 6.8.12-37 is implicated).

## Pre-reboot facts (for the record)
- All 3 VMs (110/111/112) shut down gracefully; `onboot=1` set on all three (was UNSET —
  caught in pre-flight; without it VMs would not have autostarted even on a good boot).
- Backups fresh: nightly R2 completed 01:04–01:06 UTC same day. 13/13 volumes healthy
  at window start. Both x86 nodes cordoned+drained (x86-2 partial: Longhorn PDB blocked
  IM eviction — correct last-replica protection; only DS/IM pods remained, no CSI mounts).

## Recovery plan (auto once host boots)
VMs autostart → Longhorn auto-salvage of faulted volumes → uncordon x86 nodes → bounce
zombie pods (eve backends running on stale mounts, cached-reads only) → verify all
services → THEN: replica re-spread (one home-site copy each), Longhorn zone anti-affinity
(home/remote zone tags) so concentration cannot recur, then per-volume engine upgrades
(task #66d) as originally planned for this window.

## Lessons (to fold into plan on close)
- After ANY node outage: audit replica **placement**, not just volume health.
- Longhorn **zone anti-affinity** (node zone labels home/remote) = the systemic fix.
- Remote site needs **remote power control** (smart plug / PiKVM) before the next
  host-level operation there.
- `onboot` on Proxmox VMs is not default — assert it in the future 81-upgrade-proxmox.yml.

## Addendum (evening) — uplink died again ~30 min after manual recovery
User's console fix (eno2 up + master) + my VLAN filter fix (bridge vlan add 2-4094 dev eno2)
restored everything briefly (nodes Ready, salvage started). Host then went dark again on all
paths (~25 min after my dispatched `ifreload -a` — either ifreload re-broke it, or e1000e is
link-flapping on kernel 6.8.12-37; the 30-min-then-dead pattern favors the driver theory).
Meanwhile inside the cluster: stale IM CRs ("unknown", dead pod IPs) from the netless VM boot
blocked all salvage — purged both IM pods+CRs (one needed --force; sandboxes died with the VM
cycle); x86 longhorn-managers were zombies reporting NodeStatusUnknown — recycled; dm_crypt
not persisted on the x86 VMs (only 110 got it via guest-exec before the site dropped).
**Plan:** persistent reachability watcher armed; on any window: plant bridge self-heal timer,
read kernel log, grub-reboot to 6.8.12-20 if driver-flap confirmed. If no window by morning:
short site visit — console → GRUB Advanced → previous kernel → remote takeover.

## RESOLVED 2026-07-25 ~21:40 (validation reboot PASSED)
On-site console + remote tag-team. Root causes (final list): (1) kernel upgrade renamed both
NICs, bridge-ports stale; (2) e1000e "Detected Hardware Unit Hang" on the new kernel —
mitigated by tso/gso/gro off (canonical fix), persisted via post-up + 30s MAC-based
bridge-selfheal timer (also re-asserts enslavement + VLAN 2-4094 — the manual-rescue gap that
kept tagged VM traffic dark); (3) Longhorn IM CRs wedge after node loss (twice) — purge
procedure now known; (4) **cordon blocks Longhorn IM respawn** (user-spotted): recovery order
is nodes Ready → UNCORDON → IMs → salvage. Validation reboot T+0→T+30: host+bridge+VLAN+VMs
+nodes fully unattended (PASS); salvage needed the uncordon (runbook fix) + IM purge.
All 13 volumes healthy, all services verified, tailscaled self-recovered, wazuh "changed"
host key verified genuine via qm guest exec (stale ECDSA pin, no MITM).
Kernel 6.8.12-37 KEPT (no pin) — offload fix proven under load.
