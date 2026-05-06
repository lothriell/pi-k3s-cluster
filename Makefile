# =============================================================================
# Raspberry Pi CM5 K3s Cluster - Makefile
# =============================================================================
#
# This Makefile orchestrates the provisioning and management of a K3s
# Kubernetes cluster running on Raspberry Pi Compute Module 5 nodes.
#
# Usage:
#   make              - Show this help message
#   make all          - Full cluster build from scratch
#   make status       - Quick health check
#   make nuke         - Tear everything down (destructive!)
#
# Prerequisites:
#   - Ansible, kubectl, helm installed locally
#   - SSH access to all Pi nodes
#   - Inventory configured in ansible/inventory/
#
# =============================================================================

.DEFAULT_GOAL := help

# Node addresses (adjust to match your network)
# These should match the hostnames/IPs in ansible/inventory/hosts.yml
PI_1 := rpi-k3s-1
PI_2 := rpi-k3s-2
PI_3 := rpi-k3s-3
PI_4 := rpi-k3s-4
X86_1 := k3s-x86-1
X86_2 := k3s-x86-2
PI_USER := ansible

# Ansible flags
ANSIBLE_PLAYBOOK := ansible-playbook
ANSIBLE_DIR := ansible/playbooks

# Helm repos (added idempotently in targets that need them)
HELM := helm
KUBECTL := kubectl

# =============================================================================
# Core Targets
# =============================================================================

.PHONY: help
help: ## Show all available targets with descriptions
	@echo ""
	@echo "  Raspberry Pi CM5 K3s Cluster"
	@echo "  ============================="
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""

.PHONY: all
all: prepare k3s cert-manager post-install metallb tailscale longhorn backup restore-volumes monitoring gitea argocd cloudflare trivy-operator headlamp network-policies pihole-monitor backup-relabel ## Full cluster build (prepare -> ... -> pihole-monitor -> backup-relabel)

# =============================================================================
# Provisioning Stages
# =============================================================================

.PHONY: flash
flash: ## Flash a CM5 node: make flash NODE=rpi-k3s-1 [IMAGE=path/to/image]
	@scripts/flash-node.sh $(NODE) $(IMAGE)

.PHONY: bootstrap
bootstrap: ## Create 'ansible' service account on all Linux cluster nodes (run once, uses your personal account)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/00-bootstrap-user.yml --ask-become-pass

.PHONY: bootstrap-macos
bootstrap-macos: ## Create 'ansible' service account on macOS hosts (macmini, etc.) — run once
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/00-bootstrap-macos-user.yml --ask-become-pass

.PHONY: bootstrap-manual-node
bootstrap-manual-node: ## Create 'ansible' service account on a standalone Ubuntu node (Wazuh etc.) — pass HOSTS=security_stack
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/00-bootstrap-user.yml --ask-become-pass -e "target_hosts=$(HOSTS)"

.PHONY: shell
shell: ## Setup zsh + oh-my-posh + eza on all Linux nodes (for personal user)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/00-setup-shell.yml

.PHONY: shell-macos
shell-macos: ## Setup zsh + oh-my-posh + eza + ghostty config on macOS nodes
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/00-setup-shell-macos.yml

.PHONY: prepare
prepare: ## Prepare nodes (packages, config, networking)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/01-prepare-nodes.yml

.PHONY: k3s
k3s: ## Install K3s on server and agents
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/02-install-k3s.yml

.PHONY: post-install
post-install: ## Post-install tasks (kubeconfig, labels, etc.)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/03-post-install.yml

# =============================================================================
# Service Deployments
# =============================================================================

.PHONY: metallb
metallb: ## Deploy MetalLB load balancer via Helm
	$(HELM) repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
	$(HELM) repo update
	$(HELM) upgrade --install metallb metallb/metallb \
		-n metallb-system \
		--create-namespace \
		--wait
	@METALLB_RANGE=$$(grep '^metallb_ip_range:' ansible/inventory/group_vars/all/main.yml | sed 's/metallb_ip_range: *//' | tr -d '"'); \
		if [ -z "$$METALLB_RANGE" ]; then echo "ERROR: metallb_ip_range not found in group_vars/all/main.yml" >&2; exit 1; fi; \
		sed "s|{{ metallb_ip_range }}|$$METALLB_RANGE|g" k8s/metallb/metallb-config.yml.j2 > /tmp/metallb-config.yml
	$(KUBECTL) apply -f /tmp/metallb-config.yml

.PHONY: cert-manager
cert-manager: ## Deploy cert-manager + internal-CA ClusterIssuer chain (seeds CA from vault.yml if available)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/17-deploy-cert-manager.yml

.PHONY: trust-ca-export
trust-ca-export: ## Export the homielab root CA cert to /tmp/homielab-ca.crt for client trust
	@$(KUBECTL) -n cert-manager get secret homielab-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/homielab-ca.crt
	@echo "Root CA exported to /tmp/homielab-ca.crt"
	@echo "Trust steps for Mac / Windows / iPad: see docs/internal-ca-trust.md"
	@$(KUBECTL) -n cert-manager get secret homielab-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d \
	  | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true

.PHONY: trust-ca-push
trust-ca-push: ## Push the homielab root CA to all macOS nodes (System Keychain) via Ansible
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/16-trust-homielab-ca.yml

.PHONY: ca-backup
ca-backup: ## Capture the live homielab CA cert+key into vault.yml so a rebuild can restore the same root
	@scripts/ca-backup.sh

.PHONY: monitoring
monitoring: ## Deploy monitoring stack (Prometheus, Grafana, etc.)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/04-deploy-monitoring.yml

.PHONY: gitea
gitea: ## Deploy Gitea git server
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/05-deploy-gitea.yml

.PHONY: forgejo
forgejo: ## Deploy Forgejo git server (personal repos, Windows sync)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/06-deploy-forgejo.yml

.PHONY: argocd
argocd: ## Deploy ArgoCD for GitOps continuous deployment
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/07-deploy-argocd.yml

.PHONY: cloudflare
cloudflare: ## Deploy Cloudflare tunnel for external access
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/06-deploy-cloudflare.yml

.PHONY: pihole-monitor
pihole-monitor: ## Deploy Pi-hole DNS monitor on athena (ntfy + Promtail + alert rules)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/10-deploy-pihole-monitor.yml

.PHONY: trivy-operator
trivy-operator: ## Install Trivy Operator (Helm) into trivy-system ns and scrape CVEs/configs
	$(HELM) repo add aqua https://aquasecurity.github.io/helm-charts/ 2>/dev/null || true
	$(HELM) repo update aqua
	$(HELM) upgrade --install trivy-operator aqua/trivy-operator \
		-n trivy-system \
		--create-namespace \
		-f k8s/trivy/values-trivy-operator.yml \
		--wait --timeout 5m

.PHONY: headlamp
headlamp: ## Deploy Headlamp Kubernetes web UI dashboard
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/14-deploy-headlamp.yml

.PHONY: vaultwarden
vaultwarden: ## Deploy Vaultwarden (self-hosted Bitwarden) LAN-only at vault.<local_domain>
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/20-deploy-vaultwarden.yml

.PHONY: authentik
authentik: ## Deploy Authentik (LAN-only OIDC for Grafana + ArgoCD) at authentik.<local_domain>
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/15-deploy-authentik.yml

.PHONY: network-policies
network-policies: ## Apply all namespace NetworkPolicies (requires target namespaces to exist)
	$(KUBECTL) apply -f k8s/network-policies/

.PHONY: wazuh-agent
wazuh-agent: ## Install Wazuh agent on target hosts (HOSTS=sff_nodes by default)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/13-deploy-wazuh-agent.yml $(if $(HOSTS),-e "target_hosts=$(HOSTS)",)

.PHONY: backup
backup: ## Configure etcd + Longhorn backups (local snapshots + R2 offsite)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/11-configure-backups.yml

.PHONY: backup-relabel
backup-relabel: ## Re-apply backup labels after services come up (called at end of `make all`; also run after any one-off `make vaultwarden`/`make forgejo`/etc.)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/11-configure-backups.yml --tags longhorn

.PHONY: restore-volumes
restore-volumes: ## Restore stateful PVCs from R2 backups (runs after longhorn+backup on rebuild)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/12-restore-volumes.yml

.PHONY: restore-volumes-dry-run
restore-volumes-dry-run: ## Print which PVCs would be restored from R2 (safe, read-only)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/12-restore-volumes.yml --tags "preflight,discover,resolve"

.PHONY: longhorn
longhorn: ## Deploy Longhorn distributed storage
	$(HELM) repo add longhorn https://charts.longhorn.io 2>/dev/null || true
	$(HELM) repo update longhorn
	$(HELM) upgrade --install longhorn longhorn/longhorn \
		-n longhorn-system \
		--create-namespace \
		-f k8s/longhorn/values-longhorn.yml \
		--wait --timeout 5m
	$(KUBECTL) patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

.PHONY: tailscale
tailscale: ## Deploy Tailscale for secure remote access (subnet router on server node)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/08-deploy-tailscale.yml

# =============================================================================
# Cluster Operations
# =============================================================================

.PHONY: status
status: ## Show cluster node and pod status
	@echo "--- Nodes ---"
	$(KUBECTL) get nodes -o wide
	@echo ""
	@echo "--- All Pods ---"
	$(KUBECTL) get pods -A

.PHONY: nuke
nuke: ## Destroy the entire cluster (DANGEROUS)
	@scripts/nuke-cluster.sh

.PHONY: ping
ping: ## Test Ansible connectivity to all nodes
	ansible all -m ping

# =============================================================================
# SSH Convenience Targets
# =============================================================================

.PHONY: ssh-1
ssh-1: ## SSH into rpi-k3s-1 (HA server, cluster-init)
	ssh $(PI_USER)@$(PI_1)

.PHONY: ssh-2
ssh-2: ## SSH into rpi-k3s-2 (HA server, joining)
	ssh $(PI_USER)@$(PI_2)

.PHONY: ssh-3
ssh-3: ## SSH into rpi-k3s-3 (HA server, joining)
	ssh $(PI_USER)@$(PI_3)

.PHONY: ssh-4
ssh-4: ## SSH into rpi-k3s-4 (agent)
	ssh $(PI_USER)@$(PI_4)

.PHONY: ssh-x86-1
ssh-x86-1: ## SSH into k3s-x86-1 (Proxmox VM agent, remote site)
	ssh $(PI_USER)@$(X86_1)

.PHONY: ssh-x86-2
ssh-x86-2: ## SSH into k3s-x86-2 (Proxmox VM agent, remote site)
	ssh $(PI_USER)@$(X86_2)
