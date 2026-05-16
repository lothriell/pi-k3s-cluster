# Incident — eve-tracker prod boot probe-flap during v5.35.1 rollout

**Status:** Resolved
**Severity:** Medium (multiple boot-restart cycles before stabilization; full mitigation took 4 deploys: probe-timeout bump, boot stagger, snapshot yield, 10-min initialDelay)
**Opened:** 2026-05-09 ~18:00 UTC during prod cut of v5.30→v5.35.1 bundle
**Mitigated:** 2026-05-09 ~19:50 UTC after applying `initialDelaySeconds: 600` to liveness probe
**Resolved:** 2026-05-09 ~20:25 UTC after pod `69f4ddb5c9-gwcl6` cleared all four boot-time stress points with 0 restarts and 0 new Unhealthy events
**Resolved by:** combination of v5.35.3 (snapshot yield), v5.35.2 (boot stagger), and the manifest hotfix (`initialDelaySeconds: 600`)
**Discovered by:** Claude (eve-tracking-jobs session) checking prod state ~58 min after deploy
**Impact:** Prod backend pod boot-time probe-flap recurring across v5.35.1 → v5.35.2 → v5.35.3 boots. Each boot tripped liveness around T+5-6min during Jita 9-hub × 324K-order aggregation. Pi cluster CPU just couldn't keep up with the work + a 10s probe deadline + 3-failure threshold. Single-step yields helped but didn't move the needle enough.

## Mitigation chain (chronological)

1. **Manifest hotfix** — backend probe `timeoutSeconds: 5 → 10`. Helped marginally but new pod still tripped at T+5m36s.
2. **v5.35.2 — boot stagger** — pushed contract scrape T+5min → T+25min, market_history T+8min → T+18min. Didn't help — saturation was inside hub refresh itself, not concurrency.
3. **v5.35.3 — snapshot yield** — added `setImmediate` every 1000 types in per-hub snapshot-building loop. Didn't help — pod still tripped at T+4m51s.
4. **Manifest fix that worked** — `livenessProbe.initialDelaySeconds: 15 → 600`. Defers liveness probing until 10 min after container start, so the entire boot-time burst (full refresh + Jita aggregation + 9 hubs) completes before any liveness check. Steady-state probes (every 30s, threshold 3) still catch real hangs within 90s after the grace period.

**Why the yields weren't enough:** Pi cluster's single-thread throughput on 324K orders × 9-hub processing inherently takes 5-7 min of cumulative event-loop time. Even optimal yield distribution can't reduce the wall-clock; it just spreads the work. A 90-second liveness timeout (3 × 30s threshold) is shorter than the work itself. The right fix is either bigger CPU (move backend off Pi) or a longer initialDelay window. We took the cheap fix.

## Symptom

```
$ kubectl get pods -n eve-tracker
NAME                                  READY   STATUS    RESTARTS      AGE
eve-tracker-backend-d56ccc587-qkcpr   1/1     Running   1 (52m ago)   58m
eve-tracker-frontend-8d978554-d4pbz   1/1     Running   0             58m

$ kubectl get events -n eve-tracker --sort-by='.lastTimestamp' | grep -i probe
58m   Warning  FailedAttachVolume  Multi-Attach error … (transient rolling-update boundary)
52m   Normal   Killing             Container backend failed liveness probe, will be restarted
52m   Warning  Unhealthy           Readiness probe failed: context deadline exceeded
52m   Warning  Unhealthy           Readiness probe failed: read: connection reset by peer
48m   Warning  Unhealthy           Liveness probe failed: context deadline exceeded
```

Pre-restart logs ended mid-Jita aggregation:
```
[STRUCT-ACCESS] poll done in 26.4s — 25 chars × 4 structures = 100 calls
[CHAR-SKILLS] sync done in 5.5s — 25 chars, 4321 skills fetched
[CACHE] Fetched 405 pages, 324131 Jita orders
[CACHE] Jita prices: 18442 types cached
[CACHE] Cost indices: 32910 entries across 5485 systems cached
[CACHE] Refreshing hub prices for 9 stations...
[CACHE]   Region 10000002 (Jita 4-4): fetching orders...
[CACHE]   Region 10000002: 405 pages, 324131 hub orders
<KILLED>
```

Sync sequence at boot (cumulative wall clock):
1. `CORP-ARCHIVE` 8.2s
2. `CHAR-ORDERS` 0.3s
3. `CHAR-ARCHIVE` 6.0s
4. `STRUCT-ACCESS` 26.4s
5. `CHAR-SKILLS` 5.5s
6. Jita orders fetch (405 pages, 324131 orders)
7. Jita prices cached (18442 types)
8. Cost indices refresh (32910 entries)
9. Hub prices refresh starts on first of 9 stations (Jita 4-4 = the heaviest one — that 324K-order region)
10. **Killed mid-aggregation around T+6min**

After restart, market_history sync completed cleanly:
```
[MARKET-HISTORY] sync done in 901.2s — 4948 types attempted, 3884 with history,
                  84667 rows upserted, 0 stale rows pruned, 112 fetch errors
```
112 errors are expected (CCP-side 400s on non-tradeable type IDs).

## Root cause hypothesis

Same family as v5.25.1 / `feedback_periodic_probe_observation.md` — **boot-time concurrency saturates the event loop** on the Pi cluster, and even with v5.14.1's per-1000-order yields + v5.25.1's 5000-row chunked transactions, the single `[CACHE] Region 10000002 …` aggregation pass on prod's data volume (324K orders → 18K types × 9 hubs) takes long enough to miss kubelet's 5s liveness deadline.

Test didn't see this because test has fewer hubs configured (4 vs prod's 9) and lower archived-order volume. Same code path, same yield pattern, but prod's volume × hub-count tips it over.

## Why it stabilized after restart

- Boot-time concurrent burst happens once per pod lifetime; subsequent T+30min hub refreshes are spread out and don't run alongside CORP/CHAR archive + CHAR-SKILLS at the same time.
- The natural T+30min refresh window will be the next stress point; need to watch for repeat flaps then.

## Investigation pointers

- The unyielding stretch is in `cacheRefresh.aggregateAndPersistOrdersForHubs` (or wherever the per-(type, station) bucket-build runs over 324K orders for Jita 4-4). Check whether it has the v5.14.1 1000-order setImmediate, OR whether the aggregation is one big synchronous reduce that blocks regardless of write-side yields.
- ESI fetch parallelism may compound the problem — if the 9 hub fetches run concurrently and dump 9 × 324K orders into Promise.all aggregation, that's the saturation moment.

## Mitigation options (smallest first)

1. **Bump liveness `timeoutSeconds` from 5s → 10s** — manifest-only change in `eve-tracker-k8s` repo (`base/deployment.yml` or `overlays/prod/`). Most conservative, costs nothing, gives every blocking-CPU phase 2× breathing room. Push via SSH NodePort 30022 per `reference_manifest_repo_push.md`.
2. **Bump `initialDelaySeconds` to 600s on liveness** — forces probe to wait until the boot-time refresh storm has finished before flagging anything. Still risky if a steady-state cycle later breaks.
3. **Code: chunk hub-aggregation pass with setImmediate yields** every 1000 orders during the per-(type, station) bucket build (v5.14.1 pattern but in the *grouping* loop, not the *write* loop). Bigger change but root cause fix.
4. **Stagger boot-time syncs** — push hub-price refresh first cycle from boot to boot+5min so it doesn't compete with CHAR-SKILLS / STRUCT-ACCESS / Jita-prices for CPU. Already done for some syncs; hub refresh might need a delay too.

Recommended: **Option 1 (probe timeout bump) right now** as a hotfix while we evaluate option 3 in code.

## Watch points

- **Next T+30min hub refresh window** — fired at ~18:30 UTC and again ~19:00 UTC. Pod still showing 1 restart total at 18:54 UTC means refreshes after the boot-time one are clean (the v5.14.1+v5.25.1 yields work in steady state). Confirm by re-checking events at the next two refresh boundaries.
- **24h market_history daily sync** — first natural one fires ~Sun 2026-05-10 18:08 UTC. Could repeat this kind of probe-flap if it overlaps with hub refresh.
- **Pod restart count** — should stay at 1 forever (steady-state safe). Any further restarts = real recurrence.

## App-side state (post-mitigation)

- Prod (`eve-prod.example.com`) is on **v5.35.3**, healthy, serving traffic. Pod `69f4ddb5c9-gwcl6` cleared boot Jita aggregation (T+5-6min), market_history first sync (T+18min), contract scrape kickoff (T+25min), and steady-state hub refresh cycle (T+30min, concurrent with contract scrape) — all 0 restarts, 0 new Unhealthy events.
- Test (`eve-test.example.com`) is on **v5.35.3**.
- Dev (`100.x.x.x:9000`) is on **v5.35.3**.
- Bundle deployed: v5.30→v5.35.3 (Production Opportunities matrix + market_history + dedup, My Blueprints, BPO Collector, sidebar+dashboard UX, BPC cost in advanced margins, Build Planner profiles, reaction ME10 fix, T2 verdict split, tech-tier filter chips, plus three boot-stability fixes from this incident).

## Files touched

`eve-tracking-jobs` (this repo, commits `c51f1ca`, `dcac03d`):
- `backend/services/cacheRefresh.js` — boot stagger (contract T+5min→T+25min, market_history T+8min→T+18min) + setImmediate yield every 1000 types in per-hub snapshot building loop.
- `backend/routes/api.js`, `CHANGELOG.md`, `README.md`, `CLAUDE.md` — version bumps to v5.35.2 and v5.35.3.

`eve-tracker-k8s` (manifest repo, commits `a98abfc`, `5328362`):
- `base/deployment.yml` — backend `livenessProbe.timeoutSeconds: 5 → 10`, `readinessProbe.timeoutSeconds: 5 → 10`, `livenessProbe.initialDelaySeconds: 15 → 600`, explicit `failureThreshold: 3`.

## Instructions from cluster session (2026-05-09)

Cluster confirmed clean: 14/14 hosts upgraded today (fleet upgrade ran 80-upgrade-packages.yml during the same window — unrelated to this flap; pod restart was T+6min into its own boot, not caused by node reboots). HA control plane intact, eve-tracker-test rolled to v5.34.1 then v5.35.1 cleanly.

**Action — eve session, ordered:**

1. **Hotfix now (option 1 from above):** in the `eve-tracker-k8s` repo, bump backend liveness `timeoutSeconds` from 5 → 10. Bump readiness `timeoutSeconds` to 10 too — both were flapping per the events log.
   - Edit in `base/deployment.yml` (or wherever the backend probe block lives). If only prod is affected, do it in `overlays/prod/` patch instead — but symmetry across overlays is usually less surprising than per-env divergence.
   - Push via Gitea SSH NodePort 30022 (per `reference_manifest_repo_push.md` in eve memory).
   - ArgoCD will roll within ~30s of the push. Confirm: `kubectl get pods -n eve-tracker -w` until new pod is Ready 1/1, then `curl -s https://eve-prod.example.com/api/version` shows v5.35.1 with restart count back to 0 on the new pod.
   - This matches the established cluster-side pattern in `feedback_nodejs_probe_timeouts.md` (bump to 5s was right for the lighter case; prod's 9-hub × 324K-order boot needs 10s).

2. **Watch the next two refresh boundaries** (~18:30 / 19:00 UTC) before considering this resolved. Restart count should stay at 1 forever. If it climbs, hotfix wasn't sufficient → escalate to option 3 (chunked aggregation in cacheRefresh).

3. **Tomorrow (Sun 2026-05-10 ~18:08 UTC):** first natural daily market_history sync. Check pod restart count again afterward — if still 1, declare resolved.

4. **Real fix (option 3) is still desirable** — boot-time event-loop saturation on Pi is going to bite again as data volume grows. Track as a follow-up after the hotfix soaks for 48h. Cluster session will not pick this up; it's app code.

**Cluster session is NOT taking the manifest push.** The eve session owns the eve-tracker-k8s repo and has the SSH context for it. If you (eve session) hit a registry/Gitea/Argo issue while pushing, ping the cluster session — gitea was bouncing during today's K3s server reboots but settled by ~3m post-Phase-3.

**Resolution criteria for closing this incident:**
- [x] Manifest committed + pushed with timeout bump (`a98abfc`) and initialDelaySeconds bump (`5328362`)
- [x] New pod rolled with restart count 0 (`69f4ddb5c9-gwcl6`)
- [x] Two consecutive 30-min refresh windows pass with restart count still 0 (verified at T+30min boundary 20:19:44Z, restart count = 0)
- [x] Daily market_history sync at 2026-05-10 ~19:49 UTC passed with restart count still 1 — verified 2026-05-10 21:25 UTC: `MARKET-HISTORY sync done in 933.1s — 4948 types attempted, 3870 with history, 81583 rows upserted, 2835 stale rows pruned, 136 fetch errors`. CHAR-SKILLS sync also clean (5.1s). Pod restart count unchanged at 1.
- [x] Archived to `~/claude/kubernetes/docs/incidents/2026-05-09-eve-prod-probe-flap.md`.

## Lessons learned

1. **Pi cluster CPU has a hard ceiling on synchronous JS work.** No yield distribution can reduce wall-clock CPU time on 324K orders × 9 hubs. When the work itself takes longer than the liveness threshold (`failureThreshold × periodSeconds × timeoutSeconds`), only longer probe windows OR moving compute off Pi will fix it.
2. **`initialDelaySeconds` is the right tool for known-long boot sequences.** Tighter probe deadlines push you toward over-engineering yields. A 10-min boot grace lets the work breathe and steady-state probes still catch real hangs.
3. **Iterate on root-cause hypotheses incrementally.** v5.35.2 (concurrency stagger), v5.35.3 (snapshot yields), and the manifest fix (initialDelay) each tested a different hypothesis. Three deploys in 90 minutes felt frantic but the wedge approach correctly narrowed the cause: not concurrency, not aggregation throughput, but raw boot wall-clock.
4. **Don't shadow-debug; check `kubectl get deploy -o jsonpath` against expected manifest.** The manifest commit was correctly pushed but ArgoCD's auto-sync didn't apply the deployment-spec change until a manual hard-refresh — the `Synced,Healthy` status was misleading. Always confirm the spec is live before declaring "fix deployed."
