# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

K3s Kubernetes cluster with mixed-architecture nodes, fully automated with Ansible. The cluster is designed to be destroyed and rebuilt from scratch in minutes.

**ARM64 nodes:** 4x Raspberry Pi CM5 (16GB RAM, 32GB eMMC) — home site
**x86 nodes:** 2x Proxmox VMs (4 vCPU, 16GB RAM, 50GB disk) — remote site
**OS:** Ubuntu 24.04 LTS on all nodes
**Networking:** Two sites connected via UniFi Site Magic VPN
**Users:** personal user (for bootstrap), `ansible` (service account with passwordless sudo)

## Common Commands

```bash
# Full cluster lifecycle
make all                    # Build everything from scratch
make nuke                   # Destroy cluster (interactive confirmation)

# Individual stages (run in order)
make bootstrap              # Create ansible user on new nodes (first time, uses -K for sudo password)
make shell                  # Deploy zsh/oh-my-posh/eza to all nodes
make prepare                # System prep (packages, swap, kernel modules, registry config)
make k3s                    # Install K3s server + agents
make post-install           # Helm repos + namespaces
make metallb                # MetalLB load balancer
make tailscale              # Tailscale VPN (subnet router on server node)
make longhorn               # Longhorn distributed storage
make monitoring             # Prometheus + Grafana
make gitea                  # Gitea git server (+ container registry)
make argocd                 # ArgoCD GitOps (+ Image Updater)
make cloudflare             # Cloudflare tunnel
make cert-manager           # TLS certificates

# Operations
make status                 # kubectl get nodes + pods
make ping                   # Ansible connectivity test
make ssh-1 through ssh-4    # SSH into specific nodes

# Run specific playbook with tags
ansible-playbook ansible/playbooks/01-prepare-nodes.yml --tags kernel
# Limit to specific nodes
ansible-playbook ansible/playbooks/00-bootstrap-user.yml --limit rpi-k3s-1 -K -u <your-user>
```

## Architecture

### Cluster Topology

```
Home Site (home subnet)                Remote Site (remote subnet)
┌─────────────────────┐                ┌──────────────────────┐
│ rpi-k3s-1 (control) │                │ k3s-x86-1 (agent)    │
│ rpi-k3s-2 (agent)   │◄──Site Magic──►│ k3s-x86-2 (agent)    │
│ rpi-k3s-3 (agent)   │    VPN         │                      │
│ rpi-k3s-4 (agent)   │                │ wazuh-server (standalone)
└─────────────────────┘                └──────────────────────┘

Other managed nodes (via Tailscale):
  gpu-1 (GPU server)       — Ollama LLM serving (Docker, not K8s)
  athena, artemis,         — SFF PCs (Wazuh agents, Pi-hole on athena)
    minisforum-c
  arch-t-01, cachy-t-01    — Desktops (Arch/CachyOS)
```

### Execution Flow

`make all` chains: prepare -> k3s -> post-install -> metallb -> tailscale -> longhorn -> monitoring -> gitea -> argocd

**Bootstrap playbooks (00-*)** run as personal user and must be invoked separately.
**All other playbooks** use the `ansible` service account (configured in ansible.cfg).
**Playbooks 03-08** run on `localhost` using kubectl/helm against the cluster (except 08-tailscale which runs on nodes).
**Playbook 09** (Ollama) runs on `gpu_servers` group as personal user (Docker requires it).

**Desktop bootstrap:** Arch/CachyOS desktops use RSA key for initial bootstrap:
```bash
ANSIBLE_PRIVATE_KEY_FILE=~/.ssh/id_rsa ansible-playbook ansible/playbooks/00-bootstrap-user.yml -e target_hosts=desktops -K -u <your-user>
```
After bootstrap, `ansible` user uses `id_ed25519` like all other nodes.

**macOS bootstrap** (macmini and any other Mac host in `macos_nodes`): uses Directory Service (`dscl`) because macOS has no `useradd`. Run once with your personal account:
```bash
make bootstrap-macos           # runs 00-bootstrap-macos-user.yml --ask-become-pass
```
UID 600, primary group staff (20), shell `/bin/zsh`, home `/Users/ansible`, added to `com.apple.access_ssh` for sshd access, passwordless sudo via `/etc/sudoers.d/ansible`. Idempotent — re-runs detect existing state and skip.

**Manual-node bootstrap** (standalone Ubuntu VMs not in `k3s_cluster` — Wazuh in `security_stack`, future SFF pattern, etc.): reuses the Linux `00-bootstrap-user.yml` with a `target_hosts` override:
```bash
make bootstrap-manual-node HOSTS=security_stack
# equivalent to:
# ansible-playbook 00-bootstrap-user.yml --ask-become-pass -e target_hosts=security_stack
```
Prerequisite: cloud-init (or the OS installer) has already seeded the personal user with the MacBook pubkey. For an already-deployed VM where all creds are lost, use the Proxmox NoVNC GRUB-edit recovery procedure documented in `project_wazuh_access` memory, THEN run this bootstrap.

### Variable Flow

Inventory (`ansible/inventory/hosts.yml`) defines global vars (k3s_version, server IP, metallb range) that flow to all playbooks and roles. The K3s server role sets `k3s_node_token` as a fact, which agents consume via `hostvars[groups['k3s_server'][0]]['k3s_node_token']`.

### Helm Values Pattern

All Helm-deployed services follow: playbook in `ansible/playbooks/` references values in `k8s/<service>/values-<service>.yml` via path `{{ playbook_dir }}/../../k8s/<service>/values-<service>.yml`.

### Kubeconfig

Generated by k3s-server role, fetched to `~/.kube/config` with 127.0.0.1 replaced by the server node's IP.

### Application Deployment Pipeline

```
Developer → podman build on Mac (ARM64) → push to Gitea container registry
→ ArgoCD Image Updater (2-min poll, digest strategy) → ArgoCD syncs → pods restart
```

- K8s manifests stored in Gitea repo, structured as Kustomize overlays (base + prod/dev)
- ArgoCD Application CRDs point to Gitea repo paths
- Image Updater v1.1 uses CRDs (not annotations) to watch registry for new digests
- Supports `--dev` flag for dev environment images (`:dev` tag)

## Critical Quirks

### Gitea ROOT_URL Must Be Internal Service URL
Gitea's container registry returns a `Www-Authenticate` header based on `ROOT_URL`. If set to an external hostname, pods can't resolve the token endpoint. Must be set to `http://gitea-http.gitea.svc.cluster.local:3000`.

### Gitea Registry HTTP + K3s containerd
K3s containerd defaults to HTTPS. Nodes need `/etc/rancher/k3s/registries.yaml` to use HTTP for the Gitea registry. Nodes also need the registry hostname in `/etc/hosts` (kubelet runs outside cluster DNS). Both are configured by the Ansible common role.

### Cloud-init /etc/hosts Overwrite
Cloud-init regenerates `/etc/hosts` on every reboot. The common role disables this via `/etc/cloud/cloud.cfg.d/99-disable-manage-hosts.cfg`.

### ArgoCD Image Updater v1.1 CRD-based
Image Updater v1.1 uses ImageUpdater CRDs, not Application annotations. Requires Kustomize or Helm source type (rejects plain "Directory" manifests). Registry credentials use `env:` format in Helm values.

### Gitea Helm Rolling Update Deadlock
Gitea uses a ReadWriteOnce PVC. Rolling updates deadlock because the new pod can't mount the volume while the old pod holds it. Fix: scale to 0, then back to 1.

### unattended-upgrades Lock
Fresh Ubuntu boots run `unattended-upgrades` which holds the dpkg lock. The common role disables this service. If apt tasks fail with lock errors, stop the service first.

### K3s ServiceLB Disabled
K3s is installed with `--disable servicelb` because MetalLB handles load balancing instead. MetalLB uses L2/ARP mode with IP range configured in inventory.

### Tailscale accept-routes
Cluster nodes must NOT use `--accept-routes`. This causes them to route LAN traffic through Tailscale instead of eth0, breaking inter-node networking, MetalLB ARP, and Flannel. Only external clients should accept the subnet route.

### Tailscale SSH
All 6 K3s cluster nodes run Tailscale's built-in SSH server (`RunSSH=True`), enabled by the tailscale role via `tailscale set --ssh --accept-risk=lose-ssh`. SSH sessions are authenticated by tailnet identity (not OpenSSH `authorized_keys`), gated by the ACL policy at `login.tailscale.com/admin/acls`. Sessions route over WireGuard, so they survive LAN subnet disruption — critical for `nuke-cluster.sh` which kills the subnet route mid-run. All 3 K3s servers also advertise the cluster subnet as HA subnet routers.

### Longhorn Storage
Longhorn is the default StorageClass (2 replicas). `local-path` is still available but not default. 32GB eMMC per node — storageMinimalAvailablePercentage set to 25% to reserve space for OS upgrades.

### Prometheus Longhorn Scraping
Longhorn metrics must use `kubernetes_sd_configs` with endpoint role (not `static_configs` with service VIP). A service VIP load-balances to one random pod per scrape, losing metrics from other nodes.

### K3s Agent Token Loss on Upgrade
The K3s install script overwrites `/etc/systemd/system/k3s-agent.service.env` on every run, wiping `K3S_TOKEN`. Fix: write `server` and `token` to `/etc/rancher/k3s/config.yaml` which the install script does NOT overwrite. K3s upgrades must step through each minor version (no skipping). v1.32 auto-upgrades Traefik v2→v3.

### Gitea Admin Creation Fails on Helm Upgrade
The Gitea Helm chart's `gitea.admin.*` values trigger `gitea admin user create` in an init container. If the user already exists in the SQLite DB (from a previous install), it crashes. Fix: only pass `--set gitea.admin.*` on fresh installs, not upgrades. The playbook (05-deploy-gitea.yml) checks `helm status` first.

### Cloudflare Tunnel DNS
The `cloudflared` CLI cert (`~/.cloudflared/cert.pem`) is locked to one Cloudflare zone. Always create tunnel DNS records manually in the Cloudflare dashboard — never use `cloudflared tunnel route dns` for domains on a different zone.

### Prometheus Node-Exporter Hostname Relabeling
Node-exporter is scraped by a dedicated `node-exporter` job in `extraScrapeConfigs` that labels `instance` with the node hostname (not IP). The default `kubernetes-service-endpoints` job is disabled for node-exporter via `prometheus.io/scrape: "false"` annotation. This prevents Grafana showing duplicate nodes after upgrades or pod rescheduling.

## AI Stack

### Ollama (GPU server, external to K8s)
- Runs as Docker container on a dedicated GPU server (RTX 3090, 24GB VRAM)
- Playbook: `ansible/playbooks/09-deploy-ollama.yml` (targets `gpu_servers` group)
- Role: `ansible/roles/ollama/` (Docker + NVIDIA runtime)
- Proxied into K8s via `ollama-external` Service/Endpoints in `k8s/ingress/local-ingress.yml`
- Accessible at `ollama.<local_domain>` through Traefik
- Models: Qwen 3 32B Q4_K_M (primary), Qwen 2.5 32B Q4_K_M (legacy)

### Open WebUI (K8s)
- ChatGPT-like web interface for Ollama
- Namespace: `open-webui`
- Manifest: `k8s/open-webui/open-webui.yml`
- Connects to Ollama via `ollama-external.default.svc.cluster.local:11434`
- SQLite conversation history on a 2Gi PVC
- First signup becomes admin; disable after: `kubectl set env deployment/open-webui -n open-webui ENABLE_SIGNUP=false`
- Needs ~1Gi memory limit (OOMKills at 512Mi on ARM64)
- Accessible at `chat.<local_domain>` through Traefik

## Pi-hole DNS Monitoring

### Architecture
Pi-hole logs are monitored at two levels:
- **Log retention (Promtail → Loki):** ALL DNS queries from ALL IPs shipped to Loki on K8s. 3-month retention. Searchable in Grafana via Loki datasource.
- **Real-time alerts (Python script → ntfy):** Pattern-matched alerts with custom display labels. Sub-second latency.

### Components (deployed on athena)
- **ntfy:** Self-hosted push notification server (Docker). Auth enabled (deny-all default). Uses `upstream-base-url: https://ntfy.sh` for iOS push delivery. Exposed via Cloudflare tunnel at `ntfy.<cloudflare_domain>`.
- **Promtail:** Tails pihole.log, ships to Loki on K8s via NodePort 31100 (Docker).
- **pihole-dns-monitor:** Python script + systemd service. Matches DNS queries against alert rules and sends notifications via ntfy (localhost, no auth needed).
- **Loki:** Deployed on K8s in monitoring namespace (SingleBinary mode, 10Gi PVC, 3-month retention). NodePort 31100 for external Promtail access. Grafana Loki datasource pre-configured.

### ntfy Access
- ntfy topic and credentials are in `group_vars/all/vault.yml` (Ansible Vault encrypted)
- Phone app: subscribe to the topic at `https://ntfy.<cloudflare_domain>` with credentials from `vault.yml`
- Monitor script publishes locally (localhost:8080, anonymous write allowed on the topic)
- Athena has old Docker (no compose plugin) — ntfy and Promtail run via `docker run`, not compose

### Alert Rules
Rules live in `secrets/pihole-alert-rules.conf` (gitignored). Format:
```
domain_pattern | ip_or_* | display_label
*.sme.sk | 10.0.0.42 | duck domain        # specific IP
*.facebook.com | * | social media          # any IP
```

Day-to-day editing: SSH to athena, edit `/etc/pihole-monitor/alert-rules.conf`, then `sudo systemctl reload pihole-dns-monitor`.

### Deployment
```bash
ansible-playbook ansible/playbooks/10-deploy-pihole-monitor.yml
```

### Files
- Playbook: `ansible/playbooks/10-deploy-pihole-monitor.yml`
- Role: `ansible/roles/pihole-monitor/`
- Alert rules: `secrets/pihole-alert-rules.conf` (gitignored, copied to athena on deploy)
- Loki datasource: `k8s/monitoring/values-grafana.yml`

## Network Layout

All IPs are configured in `ansible/inventory/hosts.yml` and `group_vars/all/main.yml`. Non-secret config lives in `main.yml`; credentials live in the vault-encrypted `vault.yml` alongside it. See the `.example` files for templates.

| Resource | Description |
|----------|-------------|
| Pi nodes (ARM64) | 4 static IPs on home site cluster subnet |
| x86 VMs (AMD64) | 2 static IPs on remote site cluster subnet |
| MetalLB pool | Range of IPs for LoadBalancer services |
| K3s API | Server node IP, port 6443 |
| Tailscale subnet | Cluster subnet advertised by server node |
| Pod CIDR | 10.42.0.0/16 (K3s default) |
| Service CIDR | 10.43.0.0/16 (K3s default) |

## Security Stack

### Trivy Operator (K8s-native)
- Namespace: `trivy-system`
- Scans container images for CVEs and K8s configs for misconfigurations
- Results as CRDs: `VulnerabilityReport`, `ConfigAuditReport`
- `kubectl get vulnerabilityreports -A` / `kubectl get configauditreports -A`

### Wazuh (standalone VM)
- Separate VM on Proxmox (not a K8s workload)
- All-in-one: Manager + Indexer + Dashboard
- Agents installed on all cluster nodes + Proxmox host
- Dashboard accessible via HTTPS on Servers VLAN

## Service Credentials

Gitea and ArgoCD credentials are defined in `group_vars/all/vault.yml` (Ansible Vault encrypted, gitignored) and auto-created on deploy:
- **Gitea:** Admin account created via `--set gitea.admin.*` on fresh install (playbook 05). Skipped on upgrades (user already exists in SQLite DB).
- **ArgoCD:** Fixed admin password via bcrypt hash in `--set configs.secret.argocdServerAdminPassword`. Gitea repo secret auto-created.
- **Grafana:** admin / admin (hardcoded in values file, change after first login)
- **Open WebUI:** First signup becomes admin. Disable signup after: `kubectl set env deployment/open-webui -n open-webui ENABLE_SIGNUP=false`
- **Wazuh:** Credentials shown during install (stored on Wazuh VM)

Template: `group_vars/all/vault.yml.example` has placeholder values for `gitea_admin_user`, `gitea_admin_password`, `gitea_admin_email`, `argocd_admin_password`.

## Operational references

- **`docs/ops-commands.md`** — day-to-day commands cheatsheet (Ansible Vault, backups, alerts, ntfy, cluster health). First stop when you need to do a thing and forgot how.
- **`docs/improvement-plan.md`** — living checklist of cluster hardening work (status for each task, pointers to files to touch).

## File Conventions

- Playbooks are numbered and run in order (00-09)
- K8s manifests use `values-<service>.yml` for Helm, Kustomize overlays for apps
- Placeholder values marked with `TODO CHANGEME`
- Dotfiles for Pi shell environment live in `dotfiles/`
- `ansible.cfg` is at project root (not in `ansible/`) so it works from any subdirectory
- **Local config:** `ansible/inventory/group_vars/all/main.yml` (gitignored) holds IPs and non-secret vars. `all/vault.yml` (Ansible Vault encrypted, gitignored) holds secrets. Copy from the matching `.example` files to set up, then `ansible-vault encrypt vault.yml`. The vault password lives at `~/.ansible/vault_pass` and is referenced by `ansible.cfg`.
- **Secrets:** EVE SSO credentials, Image Updater config, and private docs are all gitignored. See `.gitignore` for the full list.
