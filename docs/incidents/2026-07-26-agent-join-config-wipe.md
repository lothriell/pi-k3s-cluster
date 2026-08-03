# Incident — `--tags config` roll wiped agent join config; all 4 agents NotReady + control-plane lease-suicide cascade

**Status:** Resolved
**Severity:** Medium
**Opened:** 2026-07-26 18:56 CEST
**Resolved:** 2026-07-26 19:03 CEST (nodes Ready; volume rebuilds completed after)
**Discovered by:** Claude session (task #64 work — the run that caused it)
**Resolved by:** same session, same hour
**Impact:** kube-vip VIP (cluster API) dark ~3 min; all 4 agent kubelets down ~7 min;
pod churn cluster-wide as controllers evicted from NotReady agents; all 13 Longhorn
volumes briefly degraded/detached, no data loss.

## Symptom
`kubectl` timed out on the VIP (<k3s-vip>:6443) minutes after an
`ansible-playbook 02-install-k3s.yml --tags config` roll (deploying etcd-expose-metrics
+ staggered snapshot crons for task #64). Node IPs pinged fine. When the VIP returned,
servers were Ready but all 4 agents were NotReady, with `k3s-agent` crash-looping on
`level=fatal msg="Error: --server is required"`.

## Root cause
Two independent faults, both triggered by the same tag-limited run:

1. **Agent join-config landmine.** The agents' live `/etc/rancher/k3s/config.yaml`
   carried `server:` + `token:` lines — the codified fix for the install-script
   token-wipe quirk (CLAUDE.md), added during the v1.36 upgrade. But the k3s-agent
   role's `config.yaml.j2` template only contained kubelet tuning. The `--tags config`
   run re-templated the file, silently deleting the join config on all 4 agents at
   once, then the notify handler restarted them into the fatal.

2. **Serial server restarts without a readiness gate.** The `restart k3s` handler
   returned as soon as systemd did; with `serial: 1` the three etcd servers restarted
   ~1 min apart while each was still replaying etcd on eMMC. The stacked I/O pushed
   applies to seconds; each server holding the k3s-cloud-controller-manager lease in
   turn failed its renew and k3s exited by design (`leaderelection lost` — same
   mechanism as the 06:00 snapshot suicide investigated the same day). One suicide
   per server (18:57:52 / 18:58:16 / ~18:59), VIP dark 18:57→19:00:48.

## Fix
- Immediate: slurped the node-token from rpi-k3s-1, appended `server:` (VIP URL) +
  `token:` to `/etc/rancher/k3s/config.yaml` on all 4 agents, restarted `k3s-agent`
  — all active within one command round.
- Codified (same commit as the task #64 work):
  - `roles/k3s-agent/templates/config.yaml.j2` now owns the join config; the role
    slurps the token from the first server under the same `config` tag, so
    tag-limited runs render a complete file.
  - `roles/k3s-server/handlers/main.yml`: `restart k3s` now waits for local
    `/readyz` (up to 10 min) + 60 s settle before the play moves to the next server.

## Aftermath — AD-controller phantom-attach wedge (found ~21:30, +2.5 h)
Four StatefulSet pods (loki, vaultwarden, trivy-server, authentik-postgresql) stayed
`ContainerCreating` for 2.5 h after the nodes recovered: kubelet looped on
`WaitForAttach ... is forbidden ... no relationship found between node 'minisforum-c'
and this object` — a node-authorizer 403 for a **VolumeAttachment that did not exist**.

Root cause: kube-controller-manager (restarted repeatedly during the cascade) rebuilt
its attach-detach actual-state-of-world from minisforum-c's stale
`node.status.volumesAttached` — state the AD controller itself maintains — so it
believed the 5 volumes were already attached and never created the VolumeAttachment
objects. Longhorn side was clean the whole time (volumes `detached`, IMs running).

Failed fix: `kubectl delete pod` — the StatefulSet recreates the pod instantly, the
volume re-enters the desired state before the phantom detach runs, and the deadlock
persists (verified: 8 min, no change). Working fix: **scale the StatefulSets to 0**
so nothing desires the volumes → phantom detach completes trivially (<30 s, all 5
`volumesAttached` entries drained) → scale back to 1 → clean attach, pods Running
within a minute.

## Verification
- All 7 nodes Ready 19:03:33; phantom-attach wedge cleared 21:41; pods-not-running
  converged to 0 and 13/13 Longhorn volumes healthy after replica rebuilds.
- Re-ran the same `--tags config` play end-to-end after the codification: agents
  adopted the template-owned join config and restarted cleanly (all 7 nodes Ready,
  VIP stayed up); second run fully idempotent (`changed=0` on all hosts). Server
  configs were already current so the gated restart handler did not fire this run —
  its `/readyz` condition was verified non-destructively (`k3s kubectl get
  --raw=/readyz` → `ok`, rc=0); the gate gets its first live exercise on the next
  real server config change.

## Lessons learned
- **A template that manages a file must own ALL of that file's live content.**
  Live-state fixes (the upgrade-day server/token append) die on the next template
  run unless folded back into the role. Same class as the rebuild-placeholder trap.
- Restarting an etcd-backed k3s server is only "done" when /readyz passes AND the
  I/O backlog drains — systemd's return says nothing. Serial without a gate is
  barely better than parallel.
- `leaderelection lost` suicides are k3s working as designed under disk starvation;
  on Pi eMMC any simultaneous multi-hundred-MB I/O on a server (snapshots, restarts,
  backups) can trigger one. The new etcd alert group (EtcdSlowApplies, EtcdFsyncSlow,
  EtcdLeaderChanges) exists to surface exactly this before it cascades.

## Files touched (commit — see task #64 commit)
- ansible/roles/k3s-agent/templates/config.yaml.j2 — join config now template-owned
- ansible/roles/k3s-agent/tasks/main.yml — token slurp under config tag
- ansible/roles/k3s-server/handlers/main.yml — readiness-gated restart handler
