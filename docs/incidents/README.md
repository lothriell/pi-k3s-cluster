# Incidents

Cluster incidents that took human or AI attention to resolve, kept around as reference for the next time something similar fires.

## Convention

- **Open / in-progress incidents** live at the repo root.
  - `incident.md` is the cluster's own queue (work in this repo: Ansible roles, K8s manifests, infra fixes).
  - Parallel projects that touch the cluster from a different conversation use `incident_<project>.md` (e.g. `incident_eve.md` for the eve-tracking-jobs session). Keeps queues separate so two sessions don't fight over the same file.
- **Resolved incidents** are moved here as `YYYY-MM-DD-<slug>.md` regardless of which root file they came from. One archive, one index.
- Open files at the root should be reduced to a stub ("no open incidents") between fires.

Each file follows the template at the bottom of this document. To open a new one:

1. Write the appropriate root file (`incident.md` or `incident_<project>.md`) using the template (Status: Open).
2. While investigating, fill in Symptom / Investigation as you go.
3. Once fixed, fill in Root cause / Fix / Verification / Lessons.
4. Flip Status to Resolved, then `git mv <root-file> docs/incidents/YYYY-MM-DD-<slug>.md`.
5. Add an entry to the table below.
6. Restore the root file's stub.

## Index

| Date | Severity | Status | Title |
|------|----------|--------|-------|
| 2026-05-04 | High | Resolved | [Gitea TLS pulls fail post cert-manager rollout](2026-05-04-gitea-tls-pulls.md) |
| 2026-05-06 | Low  | Resolved | [eve-tracker-backend probe flap from 302s cache refresh](2026-05-06-eve-backend-probe-flap.md) |
| 2026-05-09 | Low  | Resolved | [Cluster disruption (k3s-x86-2 + gitea reboot) blocks eve-tracker-test rollout](2026-05-09-cluster-disruption-blocks-test-rollout.md) |
| 2026-05-09 | Med  | Resolved | [eve-tracker prod boot probe-flap (Pi cluster CPU vs 9-hub × 324K-order Jita aggregation)](2026-05-09-eve-prod-probe-flap.md) |

## Template

```markdown
# Incident — <one-line title>

**Status:** Open | Investigating | Resolved
**Severity:** Critical | High | Medium | Low
**Opened:** YYYY-MM-DD HH:MM <tz>
**Resolved:** YYYY-MM-DD HH:MM <tz>          # only when Status: Resolved
**Discovered by:** <session/person>
**Resolved by:** <session/person + commit>   # only when Status: Resolved
**Impact:** one-liner — what user-facing thing is broken / at risk

## Symptom
What you saw. Errors, kubectl output, screenshots-as-text.

## Root cause
What was actually happening. Why it started. Pointers to the change that
introduced it (commit hash, deploy timestamp).

## Fix
What was done. Code paths, commands run, files touched.

## Verification
How you knew it was fixed. Commands run, what they returned.

## Lessons learned                # optional — only when there's something non-obvious
Patterns to remember, gotchas, monitoring gaps that should have caught this earlier.

## Files touched (commit <hash>)  # optional — useful for grep-back later
- path/one — what changed
- path/two — what changed
```
