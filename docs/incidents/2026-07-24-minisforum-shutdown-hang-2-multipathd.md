# 2026-07-24 — minisforum-c shutdown hang #2 + multipathd mount wedge on x86-1

**Status:** resolved 2026-07-24 ~22:00 (node back after power-cycle; root causes fixed)
**Impact:** minisforum-c out of the cluster ~5.5 h (16:28–21:54). loki-0, trivy-server-0,
authentik-postgresql-0 down ~5 h (multipathd wedge on their failover node). authentik-server
crashlooped (39 restarts) without its DB → PodExcessiveRestarts paged. No data loss; all other
services stayed up (every volume had a healthy x86 replica thanks to the 07-23 replica
relocation — contrast with July 11's 2.5 h Prometheus outage).

## Timeline (CEST)

- **~14:30** Fleet upgrade round 1 (`80-upgrade-packages.yml`): Phase 1 + agents rpi-k3s-4,
  x86-1, x86-2 upgraded + rebooted. Run aborts at x86-2's post-reboot Longhorn gate — the
  15-min budget expires mid-rebuild (cross-site delta resyncs at ~50%). No harm; gate worked,
  fuse too short.
- **16:2x** Round 2 (retries bumped to 60 min, pre-reboot gates added): minisforum-c pacman
  upgrade (kernel 7.1.3 → 7.1.4-1-cachyos) + reboot → **hangs at shutdown**, second time
  after 2026-07-11. Pings answer; sshd/tailscaled/k3s down. Playbook aborts (correctly).
- **16:28+5m** Pods evicted to other nodes. loki-0 / trivy-server-0 / authentik-postgresql-0
  land on k3s-x86-1 and stick in ContainerCreating: `mount … already mounted or mount point
  busy` while the host shows the devices free.
- **~17:30** Longhorn auto-replenishes the missing minisforum replicas onto x86 nodes →
  0 degraded volumes with the node still down.
- **~21:20** csi-plugin recycle (documented mount-propagation remedy) fixes authentik-pg only.
  Deeper look: **multipathd** (re-enabled by the day's apt upgrade + reboot) claimed the two
  remaining Longhorn sd devices with dm maps (`multipath -ll`: IET,VIRTUAL-DISK over 8:16 and
  8:48). `multipath -F` + `systemctl mask multipathd.socket multipathd` on BOTH x86 VMs →
  pods Running on kubelet's next mount retry.
- **21:54** User power-cycles minisforum-c; boots clean on 7.1.4, node Ready, volumes rebalance.

## Root causes

1. **Shutdown hang (both 07-11 and today):** systemd kills all containers — including the
   Longhorn instance-managers backing the local iSCSI devices — *before* unmounting the CSI
   filesystems on those devices (journal `-b -1`: shim-disconnect storm at 16:28:37, CSI
   unmount storm at 16:28:39, then journald stops — last words). The unmounts block in
   D-state flushing to a dead backend; shutdown never completes. minisforum is hit because it
   carries the most attached volumes; the box also had **no working watchdog** — CachyOS
   ships `nowatchdog` on the kernel cmdline AND `blacklist sp5100_tco`, so systemd's
   configured `RebootWatchdogSec=10min` was inert.
2. **multipathd on the x86 VMs:** apt upgrade + reboot (re)activated multipathd, which claims
   Longhorn's sd devices via dm maps → ext4 mount EBUSY even though `findmnt`/`lsof` show the
   device free. Known upstream Longhorn issue; VMs have no SAN so multipathd is pure liability.

## Fixes landed

- **Playbook `80-upgrade-packages.yml`:** (a) pre-reboot Longhorn redundancy gates (never
  reboot into a degraded pool); (b) post-reboot gate budgets 15 → 60 min (cross-site resyncs);
  (c) **`kubectl drain` before every reboot + uncordon after** — volumes detach cleanly while
  engines are alive, so the fatal unmount-after-kill situation cannot form.
- **minisforum-c:** sp5100_tco watchdog enabled persistently (`/etc/modules-load.d/` +
  `/etc/modprobe.d/blacklist.conf` shadow minus the sp5100_tco line — modules-load alone
  loses to the kmod deny-list). A future hang now self-resets in ≤10 min. `dm_crypt` also
  persisted via modules-load.d (Longhorn `KernelModulesLoaded=False` recurred on the new
  kernel; July 11's fix was a one-off modprobe).
- **x86 VMs:** multipathd flushed, disabled, and **masked** (mask survives package upgrades).
- **Follow-ups:** improvement-plan #65 (mask multipathd in common role), watchdog + module
  persistence worth adding to common-arch (folded into #65's scope on implementation).

## Lessons

- A node that pings but refuses SSH after a triggered reboot = hung shutdown; WoL cannot help
  a powered-on machine, and without a watchdog only a physical power-cycle recovers it.
- "Mount busy but device free" has TWO distinct causes now seen here: csi mount-propagation
  (fix: recycle csi-plugin) and multipathd dm claims (fix: flush + mask). Check
  `multipath -ll` before concluding propagation.
- Desktop-oriented Arch defaults (`nowatchdog`, watchdog blacklists) are actively harmful on
  servers — audit them when repurposing desktop distros as cluster nodes.
