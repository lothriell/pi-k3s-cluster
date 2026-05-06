# Incident — eve-tracker-backend probe flap from 302s cache refresh

**Status:** Resolved (eve-side fix landed; awaits deploy)
**Severity:** Low
**Opened:** 2026-05-06 10:00 CEST
**Resolved:** 2026-05-06 (eve-tracking-jobs commit pending)
**Discovered by:** Claude (kubernetes session, via Headlamp warnings)
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

## Verification (when fix lands)

- After deploy, `kubectl -n eve-tracker logs <pod> | grep "Hub price refresh complete"` should show the same totals at a similar duration but no longer overlap with `[CONTRACTS]` block timing.
- Headlamp warnings on the backend pod should drop to ~0 in a 30-min window.
- `kubectl -n eve-tracker get pod -l component=backend` restart count should stay flat across at least one full refresh cycle.

## Lessons

- Two CPU-bound boot-time tasks scheduled at fixed offsets (hub refresh at +5s, contract scrape at +120s) collide if either grows. Hub refresh ballooned from ~76s (v5.14.1 baseline) to 302s on the Pi cluster as more chars + structure markets came online. The 120s offset stopped being safe silently — no alert, just slowly increasing probe-warning counts in Headlamp.
- Cluster-side metrics caught the symptom; eve-side `[CACHE] Hub price refresh complete in Xs` log line is the canonical signal for whether the boot-time blockage is contained. Worth keeping that log explicit.
- Memory headroom is generous (97Mi/512Mi), so reach for CPU-side fixes (stagger, yield) before raising limits.
- Probes already at the Pi-friendly 5s — no more give cluster-side. All future fixes for similar symptoms have to come from the eve repo.

## Cluster-side notes (no action needed here)

- Probes already at Pi-friendly 5s — confirmed in spec, this is not a yesterday-style "default 1s" trap.
- Memory headroom is generous; the 768Mi proposal can be shelved.
- The 302s refresh log line is the cleanest instrumentation signal we have. Worth keeping it as the canonical eve-side metric for "is the boot-time blockage solved".
