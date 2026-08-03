# 2026-07-11 — minisforum-c lost on fleet upgrade; Prometheus down 2.5h; Loki history lost

**Status:** resolved 2026-07-12 00:18 (monitoring recovered page)
**Impact:** Prometheus down ~2.5 h (22:07–00:18). minisforum-c out of the
cluster ~2.5 h. Loki's 14-day log history lost (fresh PVC). No user-facing
service impact — Grafana/Gitea/apps stayed up.

## Timeline (CEST)

- **21:38** `80-upgrade-packages.yml` Phase 1 (parallel, non-cluster hosts)
  runs `pacman -Syu` + unconditional reboot on **minisforum-c** — it is in
  BOTH `sff_nodes` (Phase 1) and `k3s_x86_agents` (protected Phase 2), and
  Phase 1's host pattern didn't exclude cluster members. The machine **hung
  during reboot** (user later confirmed: stuck at shutdown after the kernel
  update to 7.1.3-2-cachyos).
- Prometheus's Longhorn volume had **only 1 replica, on minisforum-c**
  (leftover from the task #56 disk-full recovery) → volume `faulted`,
  prometheus-server down.
- **22:07** athena watchdog pages **"Monitoring is DOWN"** (heartbeat stale).
- **~23:05** new `tailscale-monitor` deploys on athena (task #63, built this
  same evening); **23:16** it pages **"Tailscale node minisforum-c offline"**.
- **23:5x** Wake-on-LAN attempted (NIC MAC recovered from the Wazuh
  syscollector DB, `sys_netiface` table on the host's agent) — no effect;
  WoL can't help a machine that is hung, not powered off.
- **00:08** user power-cycles the box. Node boots clean on the new kernel,
  k3s-agent + tailscaled up, node Ready.
- Longhorn node condition `KernelModulesLoaded=False` (`dm_crypt` not loaded
  on the new kernel) — `modprobe dm_crypt` cleared it; not the blocker for
  unencrypted volumes.
- Prometheus volume auto-salvaged once the replica's node returned →
  `attached/healthy`; prometheus-server Running. Volume bumped **1 → 2
  replicas** so a single node can no longer fault it.
- **Collateral own-goal:** loki-0 was stuck ContainerCreating on k3s-x86-1
  with a stale `/dev/longhorn/...` device node ("Can't open blockdev") left
  over from the x86 reboots. Applied the documented RWO remedy — scale to 0,
  scale to 1 — but the Loki chart renders the StatefulSet with
  `persistentVolumeClaimRetentionPolicy: whenScaled: Delete`, so the
  scale-down **deleted the PVC**, the PV (reclaim `Delete`), the Longhorn
  volume, and 14 days of log history. Loki restarted on a fresh 20Gi PVC;
  shipping resumed immediately. Loki was a documented non-backup ("high-churn
  derived data"), so no restore path existed — accepted loss, bad surprise.
- **00:18** watchdog pages "Monitoring recovered".

## Root causes

1. **Inventory group overlap** — minisforum-c in `sff_nodes` + `k3s_x86_agents`
   let Phase 1 reboot a cluster node with no safeguards.
2. **Single-replica Prometheus volume** on exactly that node.
3. **Node-Ready ≠ storage-safe** — Phase 2/3 gated only on `kubectl wait
   node Ready`, so serial reboots could (and did, for the x86 pair) proceed
   while Longhorn replicas were still rebuilding.
4. **StatefulSet PVC auto-delete** — the loki chart defaults
   `whenScaled/whenDeleted: Delete`; the "scale 0/1" remedy documented for
   Gitea/Grafana is only safe on **Deployments**.

## Fixes landed

- `80-upgrade-packages.yml`: Phase 1 hosts now `...:!k3s_cluster`; Phases 2+3
  gained a "wait for Longhorn volumes to regain full redundancy" gate after
  each reboot; Phase 5 brew is `--formula` only (plain `brew upgrade` hung
  2.5 h on a cask's interactive `sudo pkgutil`).
- `values-loki.yml`: `singleBinary.persistence.enableStatefulSetAutoDeletePVC:
  false` — applied; StatefulSet now shows `Retain/Retain`.
- Prometheus volume at 2 replicas (imperative patch — mirrors default; the
  1-replica state was itself imperative drift).
- `tailscale-monitor` role (task #63) live on athena — pages offline peers
  via ntfy in ≤20 min, metrics + Grafana "Tailscale Fleet" dashboard.

## Validation that alerting worked end-to-end

ntfy `k8s-alerts` history: 22:07 DOWN page → 23:07 re-page → 23:16
minisforum-c offline page (new monitor) → 00:09 recovered → 00:18 monitoring
recovered. Both the dead-man's-switch and the new peer monitor paged
correctly through a real outage on day one.
