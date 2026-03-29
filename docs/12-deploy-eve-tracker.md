# EVE Industry Tracker — K8s Deployment Architecture

## Overview

The EVE Industry Tracker is a web application for tracking EVE Online industry jobs, deployed to a K3s Raspberry Pi cluster and exposed publicly via Cloudflare tunnel.

```
                                    ┌─────────────────────────────────────────────┐
                                    │              K3s Cluster                    │
                                    │                                             │
Internet ──► Cloudflare ──► Tunnel ─┤──► cloudflared ──► frontend (nginx:80)     │
              (eve.yourdomain.com)  │                      │                      │
                                    │                      ├── /auth/* ──► backend:3001
                                    │                      ├── /api/*  ──► backend:3001
                                    │                      └── /*      ──► React SPA
                                    │                                             │
                                    │    backend ──► SQLite (Longhorn PVC)        │
                                    └─────────────────────────────────────────────┘
```

## Components

| Component | Namespace | Image | Notes |
|-----------|-----------|-------|-------|
| Backend | eve-tracker | `gitea.yourdomain.local/user/app-backend` | Express.js + SQLite |
| Frontend | eve-tracker | `gitea.yourdomain.local/user/app-frontend` | React + Nginx proxy |
| Cloudflared | cloudflare | `cloudflare/cloudflared:latest` | 2 replicas |

## Deployment Pipeline

```
Developer pushes code
        │
        ▼
./deploy-k8s.sh (runs on Mac)
        │
        ├── podman build ./backend  (ARM64 native, ~15-30s)
        ├── podman build ./frontend (ARM64 native, ~15-30s)
        ├── podman push --tls-verify=false → Gitea registry (HTTP)
        │
        ▼
ArgoCD Image Updater (polls every 2 min)
        │
        ├── Detects new image digest in Gitea container registry
        ├── Updates ArgoCD Application spec with new digest
        │
        ▼
ArgoCD syncs deployment
        │
        └── Pods restart with new images
```

### Key Files

| File | Purpose |
|------|---------|
| `app-repo/deploy-k8s.sh` | Build + push images with podman |
| `k8s/eve-tracker/deployment.yml` | Backend + Frontend Deployments |
| `k8s/eve-tracker/service.yml` | ClusterIP Services |
| `k8s/eve-tracker/pvc.yml` | 1Gi Longhorn PVC for SQLite |
| `k8s/eve-tracker/secret.yml` | EVE SSO credentials + session secret |
| `k8s/eve-tracker/nginx-configmap.yml` | Nginx config override for K8s service names |
| `k8s/argocd/eve-tracker-app.yml` | ArgoCD Application (Kustomize source) |
| `k8s/argocd/eve-tracker-image-updater.yml` | ImageUpdater CR for auto-deploy |
| `k8s/argocd/values-image-updater.yml` | Image Updater Helm values |
| `k8s/cloudflare/cloudflared-config.yml` | Tunnel ingress routing |

### Git Repos

| Repo | Contents |
|------|----------|
| `user/app-k8s` (Gitea, in-cluster) | K8s manifests + kustomization.yaml — ArgoCD watches this |
| `app-source` (GitHub) | Application source code |

## Authentication

EVE SSO-only (no local accounts). OAuth2 PKCE flow:

1. User visits the app URL
2. Clicks "Login with EVE Online"
3. Redirected to EVE SSO (`login.eveonline.com`)
4. Callback returns to app
5. Backend creates session, user is logged in

**No local ingress** — the EVE SSO callback is bound to the public domain. Using a different domain would break the OAuth flow because the redirect URI must match.

## Secrets (not in git)

Created manually via kubectl:

```bash
# Gitea registry imagePullSecret (for K8s to pull images)
kubectl create secret docker-registry gitea-registry \
  -n eve-tracker \
  --docker-server=gitea.yourdomain.local \
  --docker-username=YOUR_USER \
  --docker-password=YOUR_GITEA_ACCESS_TOKEN

# Gitea registry secret for Image Updater (in argocd namespace)
kubectl create secret generic gitea-registry-creds -n argocd \
  --from-literal=username=YOUR_USER \
  --from-literal=password=YOUR_GITEA_ACCESS_TOKEN

# RBAC for Image Updater to read imagePullSecret
kubectl create role gitea-registry-reader -n eve-tracker \
  --verb=get --resource=secrets --resource-name=gitea-registry
kubectl create rolebinding argocd-image-updater-registry -n eve-tracker \
  --role=gitea-registry-reader --serviceaccount=argocd:argocd-image-updater
```

## Gitea Access Tokens

| Token Name | Scopes | Used By |
|------------|--------|---------|
| `k8s-registry` | `read:package` | imagePullSecret for K8s nodes |
| `k8s-push` | `write:repository`, `write:package` | deploy-k8s.sh, pushing manifests to Gitea |

---

# Issues Encountered During Deployment

## 1. Podman defaults to HTTPS for registry

**Symptom:** `podman login` failed with TLS certificate error.

**Cause:** Podman defaults to HTTPS. Gitea runs HTTP-only behind Traefik.

**Fix:** Use `--tls-verify=false` flag:
```bash
podman login --tls-verify=false gitea.yourdomain.local
podman push --tls-verify=false ...
```

## 2. K3s nodes cannot resolve svc.cluster.local for image pulls

**Symptom:** `ImagePullBackOff` — images referenced as `gitea-http.gitea.svc.cluster.local:3000/...` failed to pull.

**Cause:** The kubelet (containerd) runs on the host OS, outside the cluster network. Kubernetes internal DNS (`svc.cluster.local`) only works inside pods, not on the node itself.

**Fix:** Changed image references to use a hostname resolvable by nodes and configured:
- `/etc/hosts` on all nodes pointing to the Traefik LB IP
- `/etc/rancher/k3s/registries.yaml` on all nodes to use HTTP:
  ```yaml
  mirrors:
    gitea.yourdomain.local:
      endpoint:
        - "http://gitea.yourdomain.local"
  ```
- Restarted K3s (server + agents) to pick up registry config

**Note:** Agent nodes did not have `/etc/rancher/k3s/` directory — it had to be created first.

## 3. K3s containerd defaults to HTTPS for registries

**Symptom:** `ImagePullBackOff` — containerd tried `https://` even with correct hostname.

**Cause:** containerd defaults to HTTPS for all registries.

**Fix:** Added `/etc/rancher/k3s/registries.yaml` (see above) to explicitly configure HTTP endpoint. Required K3s restart on all nodes.

## 4. Gitea registry auth fails with special characters in password

**Symptom:** `docker-registry` secret created with password containing `!$#&` failed to authenticate.

**Cause:** Shell escaping issues with special characters in the password when passed to kubectl.

**Fix:** Created a Gitea access token (alphanumeric, no special chars) and used that instead:
```bash
# Create token via API
curl -u 'user:pass' -X POST .../api/v1/users/USER/tokens \
  -d '{"name":"k8s-registry","scopes":["read:package"]}'

# Use token as password in secret
kubectl create secret docker-registry ... --docker-password=<TOKEN>
```

## 5. Gitea Helm chart rolling update deadlock with RWO PVC

**Symptom:** Helm upgrade created new pod, but it stuck in `Init:0/3` indefinitely.

**Cause:** Gitea uses a `ReadWriteOnce` PVC (Longhorn). The default `RollingUpdate` strategy tries to start the new pod before stopping the old one, but the new pod can't mount the volume because the old pod still holds it.

**Fix:** Scale to 0 then back to 1:
```bash
kubectl scale deployment gitea -n gitea --replicas=0
# wait for pod termination
kubectl scale deployment gitea -n gitea --replicas=1
```

**Prevention:** Could set `strategy.type: Recreate` in Gitea values, but this is a Helm chart default we don't control.

## 6. Frontend nginx.conf references Docker Compose service name

**Symptom:** Frontend nginx proxy returned 502 for `/auth/*` and `/api/*` requests.

**Cause:** The Dockerfile bakes in `nginx.conf` which proxies to `http://backend:3001` — the Docker Compose service name. In K8s, the backend service has a different name.

**Fix:** Created a ConfigMap with the corrected nginx config that proxies to the K8s service name, mounted over `/etc/nginx/conf.d/default.conf` in the frontend deployment.

## 7. ArgoCD Image Updater rejects "Directory" source type

**Symptom:** Image Updater logged `skipping app of type 'Directory' because it's not of supported source type`.

**Cause:** ArgoCD Image Updater v1.1 only supports Helm and Kustomize source types. Plain YAML manifests are detected as "Directory" type and are unsupported.

**Fix:** Added a `kustomization.yaml` to the manifest repo that lists all resources and defines the images block:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yml
  - deployment.yml
  # ...
images:
  - name: gitea.yourdomain.local/user/app-backend
    newTag: latest
```

## 8. Image Updater pullSecret format incompatible with v1.1 CRD

**Symptom:** Various `invalid credential spec` and `no valid auth entry` errors when using `pullsecret:` or `secret:` references in the ImageUpdater CR.

**Cause:** Image Updater v1.1 uses CRDs instead of annotations, and the credential format for the CRD differs from the documented annotation-based approach. The `pullSecret` field in CRDs doesn't match docker-registry secrets the same way.

**Fix:** Moved credentials to the Image Updater's Helm values as an environment variable:
```yaml
extraEnv:
  - name: GITEA_CREDS
    value: "user:<access_token>"

config:
  registries:
    - name: Gitea
      credentials: env:GITEA_CREDS
```

## 9. Gitea Www-Authenticate header points to unresolvable hostname

**Symptom:** Image Updater failed with `unable to decode token response: invalid character '<'`.

**Cause:** Gitea's `/v2/` endpoint returns a `Www-Authenticate` header that directs clients to a token endpoint URL based on `ROOT_URL`. When ROOT_URL was a placeholder or external hostname, the token URL was unresolvable from inside pods.

**Fix (partial):** Changed ROOT_URL to the local domain — but this hostname didn't resolve inside pods (CoreDNS doesn't know about custom TLDs).

**Fix (final):** Changed ROOT_URL to the internal service URL (e.g., `http://gitea-http.gitea.svc.cluster.local:3000`). This makes the token endpoint reachable from any pod in the cluster. External web access to Gitea still works through the Traefik ingress — the ROOT_URL only affects generated URLs and the registry token endpoint.

## 10. Image Updater RBAC — cannot read secrets from other namespace

**Symptom:** `User "system:serviceaccount:argocd:argocd-image-updater" cannot get resource "secrets" in the namespace "eve-tracker"`.

**Cause:** Image Updater runs in `argocd` namespace but needs to read the imagePullSecret from the app namespace.

**Fix:** Created a Role + RoleBinding in the app namespace granting the Image Updater service account access to the specific secret:
```bash
kubectl create role gitea-registry-reader -n eve-tracker \
  --verb=get --resource=secrets --resource-name=gitea-registry
kubectl create rolebinding argocd-image-updater-registry -n eve-tracker \
  --role=gitea-registry-reader \
  --serviceaccount=argocd:argocd-image-updater
```

## 11. Cloudflare tunnel DNS routed to wrong zone

**Symptom:** `cloudflared tunnel route dns` created the CNAME record in a different Cloudflare zone than intended.

**Cause:** The `cloudflared` CLI authenticates via `~/.cloudflared/cert.pem`, which is tied to a specific Cloudflare zone. It doesn't select the zone based on the hostname — it uses whichever zone the cert is associated with.

**Fix:** Manually created the CNAME record in Cloudflare dashboard for the correct zone:
- Type: CNAME (shown as "Tunnel" in UI)
- Name: subdomain
- Target: `<tunnel-uuid>.cfargotunnel.com`
- Proxy: ON

Deleted the accidental record from the wrong zone.
