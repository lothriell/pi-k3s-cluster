# Incident — k3s-x86-2 NotReady blocking eve-tracker-test rollout

**Status:** Resolved
**Severity:** Low
**Opened:** 2026-05-09 09:50 CEST
**Resolved:** 2026-05-09 10:17 CEST
**Discovered by:** Claude (eve-tracking-jobs session) during v5.34.1 → test promotion
**Resolved by:** auto-recovery — `k3s-x86-2` returned to Ready, gitea finished init, image-updater poll cycle picked up the v5.34.1 digest and pushed manifest commit; ArgoCD synced; test pods rolled.
**Impact:** Test pods (`eve-tracker-test` ns) stuck on v5.33.0 for ~30 min while the cluster recovered. v5.34.1 image was already pushed to registry but ArgoCD Image Updater couldn't reach gitea's container registry endpoint while gitea was rebooting. No prod impact (prod pods + the eve-tracker app stayed Healthy throughout).

## Symptom

`./deploy-k8s.sh --test` ran cleanly at ~09:08 (digest `d94f908`); ArgoCD hard-refresh annotation applied. After ~80 minutes the test pods were still 91-92 min old, on v5.33.0:

```
$ kubectl get pods -n eve-tracker-test
NAME                                    READY   STATUS    RESTARTS   AGE
eve-tracker-backend-557dbb78c-dktcq     1/1     Running   0          91m
eve-tracker-frontend-6b5b88b7d9-b9zcx   1/1     Running   0          92m
$ curl -s https://eve-test.example.com/api/version
{"version":"5.33.0",…}
```

ArgoCD app status:
```
$ kubectl get application eve-tracker-test -n argocd -o jsonpath='{.status.sync.status},{.status.health.status}'
Unknown,Healthy
```

Cluster state:
```
$ kubectl get nodes
NAME        STATUS     ROLES                AGE   VERSION
k3s-x86-1   Ready      <none>               23d   v1.34.6+k3s1
k3s-x86-2   NotReady   <none>               23d   v1.34.6+k3s1
rpi-k3s-1   Ready      control-plane,etcd   23d   v1.34.6+k3s1
rpi-k3s-2   Ready      control-plane,etcd   23d   v1.34.6+k3s1
rpi-k3s-3   Ready      control-plane,etcd   23d   v1.34.6+k3s1
rpi-k3s-4   Ready      <none>               23d   v1.34.6+k3s1
```

`k3s-x86-2` last heartbeat at `2026-05-09 09:43:42`, transitioned to Unknown at `2026-05-09 09:48:37`:
```
MemoryPressure   Unknown   …  NodeStatusUnknown   Kubelet stopped posting node status.
DiskPressure     Unknown   …  NodeStatusUnknown   Kubelet stopped posting node status.
PIDPressure      Unknown   …  NodeStatusUnknown   Kubelet stopped posting node status.
Ready            Unknown   …  NodeStatusUnknown   Kubelet stopped posting node status.
Taints:           node.kubernetes.io/unreachable:NoExecute
```

Knock-on effects in `argocd` namespace:
- `argocd-image-updater-controller-557d9c6f8f-wkgwn` — Restart count 1, ~5m ago (NodeNotReady eviction). Last log line is `2026-05-09T07:47:19Z` — **no poll cycle observed since the post-restart pod started**. Default poll interval is 2 min, so this is suspicious.
- `argocd-redis-74cbf7dc4d-zr49z` — Restart count 1, same window.
- `argocd-repo-server-7f8dd69974-jclpc` — Restart count 4, last 2m ago. Likely the cause of the Unknown sync status on apps.

Pod events for image-updater showed:
```
Warning  NodeNotReady    5m58s   node-controller   Node is not ready
Warning  FailedMount     4m26s   kubelet           MountVolume.SetUp failed for volume "ssh-known-hosts" : object "argocd"/"argocd-ssh-known-hosts-cm" not registered
Warning  FailedMount     4m26s   kubelet           MountVolume.SetUp failed for volume "ssh-signing-key" : object "argocd"/"ssh-git-creds" not registered
```
The mount errors look transient (re-registration race during reschedule); pod is Ready 1/1 now but not logging poll cycles.

## Investigation pointers

- Why is `k3s-x86-2` NotReady? Could be intentional (powered down for maintenance) or unintentional (host hardware / network / kubelet crash). Check from the kubernetes session — `ssh` to the box, look at `journalctl -u k3s-agent`, dmesg, etc.
- After the node returns:
  - Image-updater should auto-resume the 2-min poll. If it doesn't, restart it: `kubectl rollout restart deploy/argocd-image-updater-controller -n argocd`.
  - ArgoCD app sync status should flip from Unknown back to Synced once `argocd-repo-server` stops flapping.
- If the cluster needs to keep operating with k3s-x86-2 down for a while, drain it cleanly so the eviction taint doesn't keep flagging things: `kubectl drain k3s-x86-2 --ignore-daemonsets --delete-emptydir-data` (only if the node is actually staying down).

## App-side state (no action needed from this side until cluster heals)

- Dev (`100.x.x.x:9000`) is on **v5.35.0** (latest, includes BPC cost fix + scenario profiles + reaction ME10 fix + T2 verdict split).
- Test (`eve-test.example.com`) is on **v5.33.0**, healthy, 92 min uptime, 0 restarts. Market_history first sync ran cleanly partway (2000/4948 types when last checked). Will finish under its own paced schedule.
- Prod (`eve-prod.example.com`) untouched, on **v5.29.0** since 2026-05-08.
- Test bundle to roll once cluster heals: v5.34.1 (digest `d94f908`) — backend + frontend images both already pushed and tagged `:test` at `gitea.example.com/<user>/eve-tracking-jobs-{backend,frontend}`. Image-updater just needs to poll and pick them up.
- v5.35.0 not yet built for test/prod — would `./deploy-k8s.sh --test` once the v5.34.1 rollout completes and we can soak it.

## Resolution checklist

- [x] `k3s-x86-2` Ready (all 6 nodes Ready by 10:14 CEST)
- [x] Image-updater polling fresh — last cycle 07:53Z UTC then continued on 2-min cadence as gitea recovered
- [x] Test app sync flipped from `Unknown` back to `Synced,Healthy`
- [x] Test pods rolled to v5.34.1 — backend `eve-tracker-backend-5f4464f7dd-58rv7` 13m, frontend `eve-tracker-frontend-797f4db64c-wmqlw` 18m, both READY 1/1, 0 restarts. `curl https://eve-test.example.com/api/version` → `{"version":"5.34.1",…}`
- [ ] Skill cache 24h prod soak follow-up still pending (separate from this incident — see `tasks/todo.md`)

## Verification

```
$ kubectl get nodes
…all 6 Ready…

$ kubectl get pods -n eve-tracker-test
NAME                                    READY   STATUS    RESTARTS   AGE
eve-tracker-backend-5f4464f7dd-58rv7    1/1     Running   0          13m
eve-tracker-frontend-797f4db64c-wmqlw   1/1     Running   0          18m

$ curl -s https://eve-test.example.com/api/version
{"version":"5.34.1","name":"EVE Industry Tracker","buildDate":"2026-05-09"}
```

Transient warnings during the recovery window (now resolved, all from 13-18 min ago):
- `Longhorn CSI driver not found in the list of registered CSI drivers` — Longhorn driver hadn't re-registered yet when kubelet attempted volume mount during pod reschedule
- `Multi-Attach error for volume pvc-19f5809b-…` — old pod's volume attachment hadn't been released yet
- `Failed to pull image … 503 Service Unavailable` — gitea registry endpoint was responding 503 during its own boot

All cleared once gitea finished init and Longhorn re-registered.

## Lessons learned

1. **Cluster disruption ≠ deploy failure.** First instinct on "test pods still on old version 90 min after deploy" was to check the deploy chain (image-updater config, ArgoCD app spec). The actual root cause was a node going offline. Always check `kubectl get nodes` early when a multi-step deploy chain seems to hang — the cause may be 2-3 hops removed from the user-visible symptom.
2. **Image-updater silence ≠ stuck.** The 90-minute log gap (07:47Z → 07:53Z) was misleading — it looked like image-updater had crashed, but it had only been polling against unreachable endpoints (gitea down) and silently completing reconcile loops with `errors=2`. Need to grep for `errors=` in `Processing results` lines to confirm "polling but failing" vs "not polling."
3. **Auto-recovery worked end-to-end** — once the node came back, every other piece (image-updater poll → gitea registry → ArgoCD sync → kubelet attach → pod ready) self-healed without manual intervention. No `--no-verify`-style force-pushes or manual ArgoCD overrides were needed.

## Files touched

None on the eve-tracking-jobs side. This was a cluster-state issue, fully resolved by the cluster healing itself.
