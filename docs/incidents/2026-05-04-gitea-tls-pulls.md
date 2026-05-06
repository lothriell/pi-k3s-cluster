# Incident — Gitea container registry pulls failing on K3s nodes

**Status:** Resolved
**Severity:** High
**Opened:** 2026-05-04 ~14:00 CEST (during `eve-tracker-test` v5.21.0 deploy)
**Resolved:** 2026-05-04 ~17:30 CEST
**Discovered by:** sann + Claude (eve-tracking-jobs session)
**Resolved by:** sann + Claude (cert-manager session) — commit `4cf6fae`
**Impact:** Any K8s deployment that triggered a fresh image pull from `gitea.<local-domain>` failed with `ImagePullBackOff`. Pods scheduled before the regression kept running on cached images, so the cluster *looked* healthy until something restarted. eve-tracker-test was hard-down (502); prod eve-tracker was running but fragile.

## Symptom

`kubectl describe pod` on freshly-rolled `eve-tracker-test` backend + frontend showed:

```
Failed to pull image "gitea.<local-domain>/<personal-user>/eve-tracking-jobs-backend:test@sha256:c32451b7...":
  failed to do request: Head "https://gitea.<local-domain>/v2/.../manifests/sha256:...":
  tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Both new replicas hit `ImagePullBackOff`, x65 over 18m. Old replicas had already been terminated by the rollout (single-replica deployments + RWO Longhorn PVC), so `https://test-eve.<public-domain>` returned 502.

## Root cause

The cert-manager rollout earlier the same day (task #45, commit `91624a1`) added a cluster-wide HTTP→HTTPS redirect to Traefik via `k8s/traefik/helm-chart-config.yml`. The redirect is unconditional on the `web` entrypoint — every request gets 301'd to `:443`, including the K3s containerd image pulls that the architecture explicitly routed over plain HTTP via `/etc/rancher/k3s/registries.yaml`.

Flow:
1. containerd dialed `http://gitea.<local-domain>/v2/...` (per `registries.yaml`).
2. Traefik on `web` entrypoint 301-redirected to `https://gitea.<local-domain>/v2/...`.
3. containerd followed the redirect, attempted TLS handshake.
4. Cert was signed by `homielab-internal-ca` — which containerd's trust store didn't know about.
5. `x509: certificate signed by unknown authority` → `ImagePullBackOff`.

The eve-tracking-jobs session that wrote this report didn't have visibility into the cert-manager rollout (different parallel session), so the cause was unknown until the cert-manager session reviewed the report.

## Fix

Picked **option A** from the report's recommendation list: trust the homielab CA inside containerd. Implemented in `ansible/roles/common/`:

- New task **Drop homielab internal CA for containerd**: writes `/etc/rancher/k3s/homielab-ca.crt` from `vault.yml::homielab_ca_cert` (captured by `make ca-backup` after the cert-manager install).
- **registries.yaml task** rewritten to template conditionally — when CA is present, endpoint is `https://` and `configs.<host>.tls.ca_file` points at the dropped file. When the var is undefined (fresh cluster, no CA backed up yet), falls back to the legacy plain-HTTP behaviour so initial bring-up still works.
- New **`restart k3s` handler** — picks `k3s` vs `k3s-agent` based on `k3s_server` group membership.

Rollout:

```
ansible-playbook ansible/playbooks/01-prepare-nodes.yml --tags registry --forks 1
```

`--forks 1` keeps etcd quorum during the per-node restart (3 servers, 1 control-plane Pi agent, 2 x86 agents, ~30s each).

## Verification

- `kubectl rollout restart deployment -n eve-tracker-test` → both pods 1/1 Running in ~30s, no `ImagePullBackOff`.
- Prod `eve-tracker` rolled cleanly after — 1/1 in ~13s, fresh pull succeeded.
- `kubectl get nodes` showed all 6 nodes `Ready` after the rolling k3s restart; etcd `/readyz` returned `ok`.

## Lessons learned

- **The cluster-wide redirect has invisible blast radius.** Anything that routes through Traefik on the `web` entrypoint and isn't a browser is at risk. Document the redirect's effect in the relevant Critical Quirks entry so future-us isn't surprised when the next "thing that pulled over HTTP" breaks.
- **Cross-session change visibility matters.** Two parallel Claude sessions on the same repo can collide; `git log` is the canonical source of "what changed today". Adding a "check recent commits" step to incident triage would have caught the cause within 1 minute instead of the original investigator's 18 minutes of dead-ends.
- **The fix only works because the CA was already in vault.** Task #45's `make ca-backup` work happened earlier in the same session as the redirect — without it, this fix would have needed a parallel kubectl extract step. The DR persistence pattern paid off the same day it was built.

## Files touched (commit `4cf6fae`)

- `ansible/roles/common/tasks/main.yml` — new CA distribution task; registries.yaml templated conditionally
- `ansible/roles/common/handlers/main.yml` — new `restart k3s` handler
- `CLAUDE.md` — "Gitea Registry HTTP" quirk renamed to "Gitea Registry HTTPS + homielab CA in containerd"
