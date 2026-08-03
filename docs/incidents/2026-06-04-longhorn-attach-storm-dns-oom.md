# Incident — Gitea volume stuck attaching → registry 503 blocks eve-tracking-jobs K8s deploy

**Status:** Resolved
**Severity:** High
**Opened:** 2026-06-04 11:42 CEST
**Resolved:** 2026-06-04 ~13:30 CEST (Claude, kubernetes session)
**Discovered by:** Claude (eve-tracking-jobs session, deploying v5.67.0 Corp Profitability Phase A)
**Impact:** Gitea container registry (`gitea.<local_domain>`) returns HTTP 503 → `deploy-k8s.sh` cannot push images and ArgoCD Image Updater cannot pull them → **all eve-tracker test + prod K8s deploys blocked**. Gitea web/git over this host also down. (Forgejo `origin` is on a different volume and is healthy — git pushes still work.)

## Symptom
`./deploy-k8s.sh --test` builds the multi-arch images fine but fails on push:

```
Error: pushing manifest list gitea.<local_domain>/<user>/eve-tracking-jobs-backend:10ffc5f:
  copying image 1/2 from manifest list: trying to reuse blob sha256:a8d2…
  at destination: pinging container registry gitea.<local_domain>:
  received unexpected HTTP status: 503 Service Unavailable
```

Registry root confirms a sustained outage, not a push-time blip:
```
curl https://gitea.<local_domain>/  → HTTP 503  (x3, ~7.5h)
```

Gitea pod stuck initializing for 7h+:
```
kubectl get pods -n gitea
  gitea-7f67994694-9ntg9   0/1   Init:0/3   0   7h28m
kubectl describe pod -n gitea …
  Warning  FailedAttachVolume  (x230 over 7h26m)  attachdetach-controller
  AttachVolume.Attach failed for volume "restored-pv-9356042d52d0" :
  rpc error: code = DeadlineExceeded
  desc = volume restored-9356042d52d0 failed to attach to node rpi-k3s-4
         (attachmentID csi-f520b5e8…)
```

## Investigation
- PVC `gitea/gitea-shared-storage` (RWO, 10Gi) is `Bound` to PV `restored-pv-9356042d52d0`; PV `volumeHandle = restored-9356042d52d0` (note: the Longhorn volume name has **no** `pv-` prefix — a name mismatch that briefly looked like the volume was missing).
- Longhorn volume **does exist** and is the problem:
  ```
  restored-9356042d52d0   state=attaching   robustness=unknown   currentNode=   specNode=rpi-k3s-4
  engine restored-9356042d52d0-e-0   state=stopped   node=<none>
  ```
  vs. its 3 sibling `restored-*` volumes which are all `attached` / `healthy`.
- Volume conditions are clean (`Scheduled=True`, no backing-image / restore / snapshot / offline-rebuild issues) → this is a **stuck attach lifecycle**, not data corruption.
- Replica health (data is intact but **single replica, no redundancy**):
  ```
  restored-9356042d52d0-r-84d2a4d3   node=k3s-x86-1   running   healthy (2026-05-09)
  restored-9356042d52d0-r-1deeba8e   node=k3s-x86-2   stopped   (last healthy 2026-06-01)
  ```
- gitea pod is pinned/scheduled on **rpi-k3s-4** (arm Pi node, `Ready`); the volume is trying to attach there but the engine never starts (`stopped`, no node). The one healthy replica lives on an x86 node (`k3s-x86-1`).

## Root cause
(working theory) Longhorn volume `restored-9356042d52d0` wedged in `state=attaching` with its engine `stopped` — the CSI attach to `rpi-k3s-4` times out (`DeadlineExceeded`) and the kubelet retries forever, so gitea's init containers never run and the registry stays 503. No node was ever set on the engine. Trigger TBD (suspected stale attachment / instance-manager hiccup on the Pi node, possibly following the k3s-x86-2 replica going stale ~2026-06-01). Not corruption — the x86-1 replica is healthy.

## Proposed fix (pending user go-ahead — reversible, no data touched)
Cycle the consumer so Longhorn re-drives a clean attach; the healthy replica preserves all data:
```bash
kubectl -n gitea scale deploy gitea --replicas=0      # drop the attach request → volume detaches
# wait for Longhorn volume state → detached
kubectl delete volumeattachment csi-f520b5e84d075568f51d9763fc1327f2b99c71cfacbffbf47bc04fc4adaa0422  # if it lingers
kubectl -n gitea scale deploy gitea --replicas=1      # fresh attach, engine starts
```
Contingency: if the fresh attach stalls again on `rpi-k3s-4`, let the pod reschedule onto an x86 node (where the healthy replica lives) — e.g. cordon rpi-k3s-4 for the reschedule or adjust placement.

## Verification (to fill once fixed)
- Longhorn volume `restored-9356042d52d0` → `state=attached`, `robustness` healthy/degraded
- `kubectl get pods -n gitea` → gitea `1/1 Running`
- `curl -s -o /dev/null -w '%{http_code}' https://gitea.<local_domain>/` → 200
- `./deploy-k8s.sh --test` pushes + ArgoCD syncs eve-tracker-test to v5.67.0

## Resolution (2026-06-04 ~13:30 CEST)
The proposed "cycle the consumer" fix was NOT sufficient — the volume was wedged by **two stacked faults**, and a clean detach/attach cycle alone kept re-wedging. Sequence that actually fixed it:

1. **Cleared the original deadlock (the trigger).** A failed nightly `critical-snapshot` RecurringJob left Longhorn snapshot CR `critical-6e8fb350-…` stuck at `readyToUse=false` (since 2026-06-02), with a `deletionTimestamp` it couldn't honour because the `longhorn.io` finalizer needs a **running engine to purge the snapshot** — which couldn't start because the attach was wedged. The snapshot's `snapshot-controller` attachment ticket pinned the volume to `rpi-k3s-4` in `state=attaching` forever (classic 3-way circular wait). Broke it by: scale gitea→0 (drops CSI ticket) → force-remove the snapshot CR's finalizer (`kubectl patch … finalizers:null`; deletes only the K8s CR, NOT replica data) → delete the now-orphaned attachment ticket from `volumeattachments.longhorn.io`. Volume reached `detached`.
2. **Recovery still blocked — orphaned engine CR.** Fresh attaches re-wedged on *both* `rpi-k3s-4` and `rpi-k3s-1`. Cause: the volume's **engine CR `restored-9356042d52d0-e-0` was stuck owned by `rpi-k3s-4`, `currentState=stopped`, `desireState=stopped`, empty `nodeID`, empty image**. Deleted the engine CR (stateless — recreated from `volume.spec.image=v1.11.1`); it came back owned by healthy `rpi-k3s-3`. Restarted the volume-owner longhorn-manager (`rpi-k3s-1`) to force re-enqueue.
3. **The actual recovery-blocker — stale replica gating the attach.** Even with a fresh engine, `volume.spec.nodeID` was correctly set to the target by the attachment controller, but the **volume controller silently refused to promote it** (`status.pendingNodeID`/`currentNodeID` stayed empty, no errors, controller near-idle). The block was the **stale `r-1deeba8e` replica on `k3s-x86-2`** (`desireState=running` but `currentState=stopped`, and its instance-manager stuck in `starting`). The instant that replica CR was deleted, the volume controller set `engine.desireState=running`/`nodeID=…` and the volume went `attached/degraded`.
4. Deleted the `Pending` gitea pod to bypass the kubelet's accumulated attach backoff → fresh pod on `rpi-k3s-2` → `SuccessfulAttachVolume` → `1/1 Running`.

**Verification:** volume `attached` (degraded, single replica → auto-rebuilding a 2nd on `minisforum-c`); gitea `1/1 Running`; `curl https://gitea.<local_domain>/` → **200** (x3); `/v2/` → **401** (correct auth challenge). eve-tracker push/pull path unblocked.

## SYSTEMIC ROOT CAUSE (found while digging into follow-ups, 2026-06-04 ~14:00 CEST)
The stale-replica-gating-attach pattern wasn't gitea-specific — it had a single upstream cause: **`systemd-resolved` was dead (inactive) on `k3s-x86-2`** while `/etc/resolv.conf` still pointed at its stub `127.0.0.53`. No resolver → all DNS on the node failed (`registry-1.docker.io: Try again`). Its Longhorn **instance-manager had been stuck `ContainerCreating` for 10h** because containerd couldn't pull the (uncached) `rancher/mirrored-pause:3.6` sandbox image. A dead IM means every replica on x86-2 is unstartable, which **gates the attach of every volume that has a replica there**. Confirmed blast radius:
- `restored-9356042d52d0` (gitea registry) — fixed via the steps above.
- `pvc-16545e04-…` (**Prometheus** TSDB) — same wedge → `prometheus-server` `0/2 ContainerCreating` 10h → Grafana had no datasource → user reported "grafana down". **Recovered automatically** once x86-2 DNS was fixed (volume attached on rpi-k3s-2, pod now replaying WAL).

**Fix:** `ssh ansible@<x86-2 tailscale-ip>` (macmini ProxyJump was unusable, see below) → `sudo systemctl enable --now systemd-resolved` → DNS restored → x86-2 IM → `running`, Prometheus volume attached. resolved had been dead since ~May 28 (journal stops there); upstream Tailscale DNS `100.100.100.100` had been flapping degraded for weeks before that.

**rpi-k3s-4 was NOT the origin** (earlier theory): its disk is healthy (`/var/lib/longhorn` dir on rootfs, Ready/Schedulable), the `device path` error was transient incident-stress, and `dm_crypt`-not-loaded is a benign cluster-wide baseline. Uncordoned and back in service.

**Side discovery — macmini Tailscale degraded:** macmini (jump host for all cross-VLAN SSH, LAN `<macmini-lan-ip>`) is healthy on the LAN — `ping` 0.68ms, sshd answers `SSH-2.0-OpenSSH_10.2` from minisforum-c — but is **relay-only on Tailscale (`nue`, no direct path) and port 22 times out via Tailscale**. This is why the normal `ProxyJump macmini` path to remote nodes was dead and I had to use direct Tailscale SSH to the x86 nodes. macmini just needs `tailscale` restarted locally/over LAN.

## LIKELY TRIGGER (found 2026-06-04 ~15:40 while investigating OOM alerts)
Multiple pods last-restarted in a tight cluster at **01:40 UTC (03:40 CEST)** — the incident onset (= when athena's watchdog paged): `longhorn-manager-dpk4n` **OOMKilled** (01:40:30), `cloudflared` (01:40:08), `kube-state-metrics` (01:40:32), `argocd-repo-server` (01:38:39), plus the stuck snapshot CR's deletionTimestamp (01:36:31) and the Longhorn VolumeAttachment sync errors (01:40-01:43). This window coincides with the **nightly Longhorn snapshot/backup recurring job**. Working theory for the true trigger: the snapshot job spiked **longhorn-manager past its 256Mi limit → OOMKilled on k3s-x86-1**, and the same snapshot run left the stuck `critical-6e8fb350` snapshot — together kicking off the attach-storm cascade. Fix shipped: **longhorn-manager memory 256Mi → 512Mi** (k8s/longhorn/values-longhorn.yml, deployed via `make longhorn`) so the manager survives snapshot-time load. Watch tonight's ~03:40 CEST snapshot run to confirm no repeat.

## Follow-up (non-blocking, needs attention)
- **Alert re-notify tuning.** With `repeat_interval: 1h` now live, "trailing" alerts that key off a lookback window re-page hourly long after the event: `PodExcessiveRestarts` (`increase(restarts_total[24h])>5`) and `ContainerOOMKilled` (last-terminated-reason) will re-page until ~03:40 CEST 06-05 when the 24h window rolls past the incident. Decided 2026-06-04 to let them age out. Consider adding `for:` or shorter windows so these don't spam for a full day after a one-off.
- [DONE] `rpi-k3s-4` — healthy, uncordoned (device-path error was transient; dm_crypt baseline cluster-wide).
- [DONE] `k3s-x86-2` DNS — `systemd-resolved` restarted+enabled; IM `running`; Prometheus recovered.
- [PARTLY DONE] **x86-2 DNS durability.** Root cause of the resolved death is NOT definitively in the logs: no reboot (26d uptime), no OOM, no systemd/resolved package change, no clean `stop` event after May 9 — yet it ended up `inactive` (Restart=always, NRestarts=0). Untraceable one-off. Mitigation shipped: **masked `apt-daily.timer` + `apt-daily-upgrade.timer`** on all 6 Ubuntu nodes + in the common role — the disabled `unattended-upgrades.service` still let timer-driven upgrades run (May 29 libgcrypt20). Flapping Tailscale DNS `100.100.100.100` (degraded UDP+EDNS0 for weeks) is a contributing irritant, not the stop cause.
- **[TODO] resolver-health alert (NodeResolverDown).** Attempted via node-exporter `systemd` collector — failed: first a dbus socket path mismatch (mount at /var/run/dbus/system_bus_socket, not /run/dbus), then **AppArmor on the Ubuntu nodes blocks node-exporter from the system D-Bus** ("An AppArmor policy prevents this sender..."). Reverted the collector + alerts (commit). Do it via the node-exporter **textfile collector** instead: systemd timer on each node → `systemctl is-active systemd-resolved tailscaled k3s` → write `/var/lib/node-exporter/textfile/node_unit_active.prom`, mount that dir into node-exporter, re-add NodeResolverDown/NodeServiceDown alerts. No dbus/AppArmor. This is the one piece of the 2026-06-04 hardening still outstanding.
- [DONE] **macmini Tailscale degraded → FIXED.** Root cause was NOT a macmini fault (sshd healthy on :22 all-ifaces, tailscaled Running/Online/key-valid). It was **relay-only because the Servers VLAN was missing from the UniFi UPnP "Select Networks" allowlist** (UPnP+NAT-PMP were globally enabled but scoped per-network) → macmini got no port mapping (`PortMapping:` empty) → no direct path → fragile DERP relay that dropped on client-network flaps. Fix: added Servers VLAN to the UPnP allowlist on the UCG Ultra (Settings → Internet → Internet 1 → Advanced → UPnP → Select Networks). After: `netcheck PortMapping: UPnP, NAT-PMP, PCP`; direct ping both ways (~38ms via `95.102.97.100:41641`); SSH over Tailscale 3/3. ProxyJump path restored.
- [DONE] **Watchdog re-notification gap.** The athena watchdog DID page ~03:40 when Prometheus died (heartbeat went stale) — but only ONCE (script was "alert once on down transition"). Fixed: `watchdog-check.sh.j2` now re-pages every `watchdog_renotify_seconds` (3600 = hourly) with "Monitoring STILL DOWN" until recovery. Also the in-cluster `critical`→ntfy route now has `repeat_interval: 1h` (was inheriting the 4h default). Deployed via `make watchdog` + `make monitoring`. (Note: in-cluster PodNotReady/etc. couldn't fire during this outage because Prometheus ITSELF was down — only the external watchdog can catch "monitoring down", which is why its re-notification matters most. The ~40-min API blackout during recovery was just the operator's lunch-break hotspot, NOT a cluster event.)
- Redundancy: confirm the `minisforum-c` gitea replica finishes rebuilding → `robustness=healthy` (2 replicas).
- Consider pinning gitea off the Pi nodes given its registry/storage criticality.
