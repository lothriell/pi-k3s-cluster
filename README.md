# Pi K3s Cluster

Lightweight Kubernetes (K3s) cluster running on 4x Raspberry Pi CM5 modules, fully automated with Ansible.

## Hardware

| Node | Hostname | Role | Specs |
|------|----------|------|-------|
| CM5 #1 | `rpi-k3s-1` | K3s Server (control plane) | 16GB RAM, 32GB eMMC |
| CM5 #2 | `rpi-k3s-2` | K3s Agent (worker) | 16GB RAM, 32GB eMMC |
| CM5 #3 | `rpi-k3s-3` | K3s Agent (worker) | 16GB RAM, 32GB eMMC |
| CM5 #4 | `rpi-k3s-4` | K3s Agent (worker) | 16GB RAM, 32GB eMMC |

- **OS:** Ubuntu 24.04 LTS (64-bit ARM)
- **Network:** Static IPs assigned via UniFi Gateway
- **Future:** M.2 NVMe 1-2TB drives via Blade HAT

## Stack

| Component | Tool | Purpose |
|-----------|------|---------|
| Kubernetes | K3s | Lightweight K8s distribution |
| Container Runtime | containerd | Bundled with K3s |
| CNI (Networking) | Flannel | Pod-to-pod networking (bundled with K3s) |
| Ingress | Traefik | HTTP/HTTPS routing (bundled with K3s) |
| Load Balancer | MetalLB | Assigns real IPs to services |
| Storage (now) | local-path-provisioner | Local eMMC storage (bundled with K3s) |
| Storage (future) | Longhorn | Distributed storage across M.2 NVMe drives |
| TLS Certificates | cert-manager | Automatic Let's Encrypt certs |
| Monitoring | Prometheus + Grafana | Metrics collection + dashboards |
| Git + CI/CD | Gitea (or GitLab) | Self-hosted git with CI/CD |
| GitOps | ArgoCD | Watches git repos, auto-deploys to cluster |
| External Access | Cloudflare Tunnel | Expose services without public IP |
| Secrets | SOPS + age | Encrypt secrets safely in git |
| Provisioning | Ansible | Automate everything |

## Quick Start

> **First time?** Start with the [Prerequisites Guide](docs/00-prerequisites.md) and work through the docs in order.

If everything is already set up on your workstation and the Pis are flashed + networked:

```bash
# Flash a CM5 node (eMMC via USB, injects cloud-init automatically)
make flash NODE=rpi-k3s-1 IMAGE=~/Downloads/ubuntu-server.img.xz

# Full cluster deployment from scratch (after all nodes are flashed + booted)
make all

# Or step by step
make prepare      # Prepare all nodes (apt packages, kernel config)
make k3s          # Install K3s server + agents
make post-install # Install Helm, configure kubectl
make monitoring   # Deploy Prometheus + Grafana
make gitea        # Deploy Gitea (lightweight git server)
make argocd       # Deploy ArgoCD (GitOps continuous deployment)
make cloudflare   # Deploy Cloudflare Tunnel
```

## Destroy and Rebuild

```bash
# Tear down everything and start fresh
make nuke
# Wait a minute, then:
make all
```

## Documentation

Read these guides **in order** if this is your first time:

| # | Guide | What You'll Learn |
|---|-------|-------------------|
| 00 | [Prerequisites](docs/00-prerequisites.md) | What to install on your Mac/PC before starting |
| 01 | [Flash Ubuntu](docs/01-flash-ubuntu.md) | How to flash Ubuntu on CM5 modules |
| 02 | [Network Setup](docs/02-network-setup.md) | Setting static IPs on UniFi Gateway |
| 03 | [Install Ansible](docs/03-install-ansible.md) | Setting up Ansible on your workstation |
| 04 | [Prepare Nodes](docs/04-prepare-nodes.md) | Running the node preparation playbook |
| 05 | [Install K3s](docs/05-install-k3s.md) | Deploying K3s cluster |
| 06 | [Kubectl Basics](docs/06-kubectl-basics.md) | Essential kubectl commands for beginners |
| 07 | [Deploy Monitoring](docs/07-deploy-monitoring.md) | Prometheus + Grafana setup |
| 08 | [Deploy Gitea](docs/08-deploy-gitea.md) | Self-hosted git server with CI/CD |
| 09 | [Cloudflare Tunnel](docs/09-cloudflare-tunnel.md) | External access without public IP |
| 10 | [Destroy and Rebuild](docs/10-destroy-rebuild.md) | Nuke the cluster and rebuild from scratch |
| 11 | [Deploy ArgoCD](docs/11-deploy-argocd.md) | GitOps - auto-deploy from git to cluster |

## Repository Structure

```
.
├── README.md                 # This file
├── Makefile                  # Simple commands for common operations
├── docs/                     # Step-by-step guides (read in order)
├── ansible/
│   ├── ansible.cfg           # Ansible configuration
│   ├── inventory/
│   │   └── hosts.yml         # Node inventory (IPs, roles)
│   ├── playbooks/            # Numbered playbooks (run in order)
│   └── roles/                # Reusable Ansible roles
├── k8s/
│   ├── namespaces/           # Namespace definitions
│   ├── monitoring/           # Prometheus + Grafana Helm values
│   ├── gitea/                # Gitea Helm values
│   ├── gitlab/               # GitLab Helm values (alternative)
│   ├── argocd/               # ArgoCD Helm values + app manifests
│   ├── cloudflare/           # Cloudflare tunnel manifests
│   ├── cert-manager/         # TLS certificate config
│   └── metallb/              # Load balancer config
└── scripts/                  # Helper scripts
```
