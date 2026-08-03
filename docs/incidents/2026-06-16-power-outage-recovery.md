# Incident — 2026-06-16 power outage recovery — RESOLVED

**Status:** FULLY RECOVERED. All 7 nodes Ready, all 13 Longhorn volumes healthy, all pods Ready. Ready to `git mv` to `docs/incidents/2026-06-16-power-outage-recovery.md`.

## Timeline
- ~16:44 — Power outage at remote site. `k3s-x86-2` VM goes down (kubelet stops posting node status). `k3s-x86-1` stayed up (38d uptime, on UPS/recovered).
- ~16:50 — Pods that lived on x86-2 (`authentik-postgresql-0`, `monitoring/loki-0`, `eve-tracker-backend`) evicted after the 300s not-ready toleration and rescheduled to `k3s-x86-1`. Their Longhorn volumes detached from x86-2 and reattached to x86-1 (device timestamps 16:50).
- 16:50–20:30 — The 3 rescheduled pods stuck `ContainerCreating` for ~3h40m. ~115 `FailedMount` events each → the "million events" the user saw. `authentik-worker` + `authentik-server` CrashLoopBackOff (couldn't reach the down postgres).

## Root cause
`MountVolume.MountDevice failed ... mount failed: exit status 32 ... /dev/longhorn/pvc-XXX already mounted or mount point busy`, but on `k3s-x86-1`:
- `/dev/longhorn/pvc-XXX` block devices existed (reattached 16:50), fs `clean` (dumpe2fs), nothing held them (`fuser` empty), and they were NOT mounted anywhere (`mount`/`findmnt` empty).
- The CSI **globalmount target dirs did not exist on the host** at all.

→ The `longhorn-csi-plugin` pod on x86-1 had lost host mount propagation (rshared) for newly-staged volumes after the failover: it staged the mount inside its own namespace (so retries saw "already mounted") but it never propagated to the host (so the host saw no dir / kubelet's mount got EBUSY). Volumes that were already mounted before the event (host namespace) were unaffected.

## Fix applied
1. `kubectl delete pod -n longhorn-system longhorn-csi-plugin-<x86-1>` → DaemonSet recreated it, re-establishing rshared propagation.
2. `kubectl delete pod` the 3 stuck workloads → clean NodeUnstage (cleared stale in-namespace mount) + fresh NodeStage on the new csi-plugin → mounted cleanly.
3. authentik-worker/server recovered once postgres was up; deleted the worker to clear backoff.
4. Force-deleted 5 ghost `Terminating` longhorn pods pinned to the down x86-2 (`--grace-period=0 --force`); replacements (csi-attacher/provisioner/resizer/longhorn-ui) already Running on other nodes.
5. Restarted wedged `alloy-hppc7` (minisforum-c) — `/-/ready` probe was timing out (1s) because it was re-tailing every pod that restarted during recovery + node-local-discovery rate-limiting.

## Verified post-recovery
- All 13 Longhorn volumes `robustness=healthy`. No degraded/faulted volumes.
- All application pods Running/Ready (authentik, loki, eve-tracker, etc.).
- 6/7 nodes Ready.

## k3s-x86-2 root cause + fix (NOT a power problem)
The Proxmox host `lab` (<pve-lab-tailscale-ip>) never went down (79d uptime); VM 111 (k3s-x86-2) was `running` the whole time (38d guest uptime, never rebooted). Diagnosed entirely via the QEMU guest agent (`qm guest exec 111 ...`) because sshd was wedged:
- Guest could ping its gateway, x86-1, the K3s API VIP, and Tailscale was connected — **network was fine**.
- Disk 6%, fs `rw`, load ~1, 13Gi free — **host resources fine**.
- **`systemd-journald` was `inactive`; last journal line `May 29 06:50:47 systemd-journald[337]: Journal stopped`.**

→ journald died May 29 (~18 days prior). With journald dead, `/dev/log` + the stdout socket stop being serviced, so any process that logs synchronously **blocks**: that's why `ssh` hung at *"banner exchange"* (sshd blocks writing the session record) and k3s-agent's logs froze on May 28/29. The node stayed Ready on network heartbeats until k3s finally wedged at 16:44 today → NotReady → pod eviction cascade (the Longhorn mount issue above).

**Fix:** `qm guest exec 111 -- systemctl restart systemd-journald` → journald active → sshd immediately reachable again. Then `ssh ... systemctl restart k3s-agent` for a clean rejoin. Node went Ready; Longhorn rebuilt the stale x86-2 replicas (7 degraded → 13 healthy, same-site, auto-healed in ~2 min).

## Follow-ups (open)
- **Why did journald die on May 29 and never restart?** No `Restart=` recovery kicked in. Consider hardening: `journalctl` storage/quotas, or a watchdog. The node ran ~18 days with frozen logging and nothing alerted — kubelet only went NotReady when k3s itself wedged.
- Consider a node-level health probe / alert for "journald inactive" or "node logs stale" (similar spirit to the monitoring-watchdog).
- Enable Proxmox VM autostart (`onboot`) wasn't the issue here, but worth confirming for both x86 VMs.
