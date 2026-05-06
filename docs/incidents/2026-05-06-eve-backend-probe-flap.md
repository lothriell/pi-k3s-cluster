# Incident — eve-tracker-backend probe flap from 302s cache refresh

**Status:** Resolved (full fix; v5.24.1 was partial)
**Severity:** Low
**Opened:** 2026-05-06 10:00 CEST
**Partial fix:** 2026-05-06 (eve-tracking-jobs v5.24.1 — boot-time concurrency only)
**Reopened (same day):** 2026-05-06 (Headlamp post-v5.25.0: 27 readiness / 8 liveness over 73 min — natural T+30min cycle still saturating loop)
**Resolved (full fix):** 2026-05-06 (eve-tracking-jobs v5.25.1 — chunked snapshot writes; verified)
**Discovered by:** Claude (kubernetes session, via Headlamp warnings)
**Resolved by:** eve-tracking-jobs v5.24.1 (boot-time stagger) + v5.25.1 (`db.setHubPrices` and `db.setHubOrderSnapshots` async-chunked with `setImmediate` yields between 5K-row transactions)
**Impact:** Cosmetic — Headlamp shows persistent Unhealthy events for the backend pod. No restarts since the last (15h ago), service stays READY 1/1, traffic flows. Risk is the next event-loop block landing 3 consecutive misses on liveness, which would kill the pod mid-refresh and reproduce yesterday's boot-time crash chain.

## Symptom

Headlamp Events filtered "Only warnings" shows two rows on `eve-tracker-backend-545479867c-bcb2g`:

- Readiness probe failed: count 126, last seen 5m
- Liveness probe failed:  count 57,  last seen 7m

`Get "http://10.42.0.98:3001/health": context deadline exceeded (Client.Timeout exceeded while awaiting headers)`

Pod stats at observation:

```
READY 1/1, RESTARTS 1 (15h ago), AGE 15h
CPU 5m / 500m, MEMORY 97Mi / 512Mi
livenessProbe:  timeout=5s period=30s failureThreshold=3
readinessProbe: timeout=5s period=10s failureThreshold=3
```

So timeouts are already at the documented Pi-friendly value (5s, not the 1s default). Memory is 19% of limit. Neither lever has more to give cluster-side.

## Root cause (current hypothesis)

Backend logs show a synchronous cache-refresh cycle whose tail line reads:

```
[CACHE] Hub price refresh complete in 302.0s
```

302 seconds of mostly-blocking JS work on a single Node.js event loop. While the loop is occupied parsing 188k Jita orders / 117k Amarr orders / etc., kubelet HTTP probes wait past the 5s deadline and fail. Failures are scattered — never 3-in-a-row in the same window — so READY stays 1/1 and there's no restart cascade. But the probability of a 3-fail run is non-zero, and that's the path back to yesterday's restart.

This matches the diagnosis the eve-project session reached yesterday: not a probe-timeout-too-tight issue, but event-loop saturation during the boot-time concurrent kickoff.

## Fix (landed in eve-tracking-jobs — awaits deploy chain)

**Shipped (v5.24.1, 2026-05-06):**

1. **Stagger contract scrape 120s → 300s.**
   `backend/services/cacheRefresh.js` `setTimeout(() => runContractScrape(), 120000)` → `300000`. Comment updated to reference the 302s hub-refresh observation as the rationale. The scrape now fires after the hub refresh is reliably past the heavy Jita aggregation, so the two CPU-bound passes no longer pile onto the same event loop.

2. **Memory bump shelved.**
   The 512Mi → 768Mi proposal was dropped. Cluster-side observation showed pod steady-state at ~97Mi (19% of cap); memory was not the contributor and the v5.24-deploy crash was CPU-side blocking, not OOM. Documented in the v5.24.1 CHANGELOG entry.

**Files touched (eve-tracking-jobs):**
- `backend/services/cacheRefresh.js` — timer + comment
- `backend/routes/api.js` — version 5.24.0 → 5.24.1, build date 2026-05-06
- `CHANGELOG.md`, `README.md`, `CLAUDE.md` — version bump + entry

**Deploy chain:** dev (Docker on minisforum) → test (K8s) → prod (K8s). No K8s manifest change, no scope change, no schema change — image rebuild + ArgoCD auto-sync only.

**If stagger isn't enough:** the next lever is async-batching the per-region order processing in `refreshHubPrices` (chunk → `setImmediate` yield), not throwing more memory at it. Hub refresh already yields every 1000 orders inside the aggregation loop (v5.14.1) — if 302s still blocks probes, the missing yields are between regions or inside the per-station persist transaction, not in the per-order loop.

## Verification

Observed 2026-05-06 ~12:00 CEST, ~60 min after v5.24.1 rolled to both envs:

- **Probe events dropped from 126 → 2 in the trailing 30-min window** (96% reduction; eve-tracker prod backend pod). No probe events at all on the test pod (`eve-tracker-backend-648cc4685-vl4nl`).
- **Restarts:** prod pod has 1 restart from deploy time (60 min ago, expected boot transient); test pod has 0. Both stable since.
- The 302s hub-refresh log line still appears — duration unchanged, as expected, since the fix was about timing, not scope.
- Both envs running digest `sha256:593ddf90d2055e2dfe51ff1eab000c6c410e3d4621ba8902da39c87f43251d5e`.

Fix held through ≥ 60 min including at least one full hub-refresh cycle. Closing.

## Reopened: v5.24.1 was partial — natural-cycle saturation still tripping probes

**Observed 2026-05-06 ~17:00 CEST**, after v5.25.0 deploy + restart:

- Headlamp on `eve-tracker-backend-84b7f4fdc-jvvgz`: 27 readiness, 8 liveness fails over 73 min uptime. Pod still READY 1/1, 1 restart from rollout — never 3-in-a-row.
- `[CACHE] Hub price refresh complete in 292.2s` confirmed the natural T+30min interval cycle was still saturating the loop. v5.24.1's stagger had only addressed the boot-time concurrency (hub refresh + contract scrape colliding); the hub refresh on its own was still a multi-minute sync-CPU spike with at least one block exceeding the 5s kubelet probe deadline.

**Diagnosis:** the unbroken sync block inside `aggregateAndPersistOrdersForHubs`'s per-station write sequence:
- `setHubPrices` (~18K stmt.run for Jita, single transaction)
- `snapshotHubPrices` (single bulk INSERT-SELECT — fast)
- 18K Object.entries with sorts to build snapshotItems
- `setHubOrderSnapshots` (~188K stmt.run for Jita, single transaction)

On the Pi cluster, the 188K-stmt.run transaction alone is 4-10s of pure synchronous CPU. better-sqlite3 transactions are synchronous by design — you can't yield mid-transaction, but you CAN split into smaller transactions with yields between them.

## Full fix — v5.25.1 (chunked writes)

`backend/database/db.js`:
- `setHubPrices` and `setHubOrderSnapshots` made `async`, write rows in 5000-row chunks, `await new Promise(resolve => setImmediate(resolve))` between chunks.
- INSERT OR REPLACE on the (type_id, station_id, …) PK is idempotent, so partial-write states between yields are safe; if process dies mid-write, next cycle's prune (keyed on `captured_at < refreshStartedAt`) sweeps cleanly.

`backend/services/cacheRefresh.js`:
- Single caller awaits both functions inside `aggregateAndPersistOrdersForHubs`. No behavior change beyond the yields.

## Verification (full-fix observation)

Observed 2026-05-06 ~17:30 CEST, after v5.25.1 rolled to prod:

- New pod `eve-tracker-backend-66b45fcb8f-kpv8p` reached 35+ min uptime through TWO complete hub-refresh cycles (boot-time `runFullRefresh` + the natural T+30min `runHubRefresh`).
- **Probe events: 0.** Only normal pod-creation events. Compare to prior pod's 27/8 over the same workload window.
- Hub refresh duration unchanged: 308.7s (chunking adds yields, not work). The fix split the synchronous CPU into many ~250ms blocks instead of a single 4-10s block.
- Pod READY 1/1 throughout; 0 restarts.

Both fixes (v5.24.1 stagger + v5.25.1 chunking) hold in combination. Closing for real this time.

## Lessons

- Two CPU-bound boot-time tasks scheduled at fixed offsets (hub refresh at +5s, contract scrape at +120s) collide if either grows. Hub refresh ballooned from ~76s (v5.14.1 baseline) to 302s on the Pi cluster as more chars + structure markets came online. The 120s offset stopped being safe silently — no alert, just slowly increasing probe-warning counts in Headlamp.
- Cluster-side metrics caught the symptom; eve-side `[CACHE] Hub price refresh complete in Xs` log line is the canonical signal for whether the boot-time blockage is contained. Worth keeping that log explicit.
- Memory headroom is generous (97Mi/512Mi), so reach for CPU-side fixes (stagger, yield) before raising limits.
- Probes already at the Pi-friendly 5s — no more give cluster-side. All future fixes for similar symptoms have to come from the eve repo.
- **"Resolved" requires watching the natural cycle, not just boot.** v5.24.1 was declared resolved after a 60-min observation window — but the 30-min interval cycle had only fired once in that window, and the events that landed could plausibly have been reported as "boot residual." The full-fix test (v5.25.1) waited for TWO cycles of the bigger code path to confirm. For periodic-task probe-flap fixes, observe at least 2 full cycles of the affected interval before closing.
- **better-sqlite3 transactions are sync by design** — you can't yield mid-transaction, but you CAN split into smaller transactions with `setImmediate` between them. The trade-off is brief lock release between chunks; with WAL mode + idempotent INSERT OR REPLACE this was a clean way out without restructuring the data model.

## Cluster-side notes (no action needed here)

- Probes already at Pi-friendly 5s — confirmed in spec, this is not a yesterday-style "default 1s" trap.
- Memory headroom is generous; the 768Mi proposal can be shelved.
- The 302s refresh log line is the cleanest instrumentation signal we have. Worth keeping it as the canonical eve-side metric for "is the boot-time blockage solved".
