#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Raspberry Pi CM5 K3s Cluster - Nuke Script
# =============================================================================

# Node list — matches the HA topology (3 Pi servers + 1 Pi agent + 2 x86 agents).
# x86 nodes use ~/.ssh/config ProxyJump aliases (see reference_ssh_routing memory).
SERVERS=("rpi-k3s-1" "rpi-k3s-2" "rpi-k3s-3")
AGENTS=("rpi-k3s-4" "k3s-x86-1" "k3s-x86-2")
SSH_USER="ansible"

# -----------------------------------------------------------------------------
# Warning
# -----------------------------------------------------------------------------
echo ""
echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  !                                                !"
echo "  !          CLUSTER DESTRUCTION SCRIPT            !"
echo "  !                                                !"
echo "  !  This will PERMANENTLY DESTROY the K3s         !"
echo "  !  cluster and ALL workloads running on it.      !"
echo "  !                                                !"
echo "  !  The following actions will be performed:       !"
echo "  !    - Uninstall K3s agent on all agent nodes    !"
echo "  !    - Uninstall K3s server on the server node   !"
echo "  !    - Back up and remove local kubeconfig       !"
echo "  !                                                !"
echo "  !  THIS CANNOT BE UNDONE.                        !"
echo "  !                                                !"
echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------
read -rp "  Type 'yes' to confirm destruction: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo ""
    echo "  Aborted. No changes were made."
    echo ""
    exit 0
fi

echo ""
echo "--- Proceeding with cluster destruction ---"
echo ""

# -----------------------------------------------------------------------------
# Uninstall K3s agents
# -----------------------------------------------------------------------------
for agent in "${AGENTS[@]}"; do
    echo "  Uninstalling K3s agent on ${agent}..."
    if ssh -o ConnectTimeout=10 "${SSH_USER}@${agent}" \
        "sudo /usr/local/bin/k3s-agent-uninstall.sh" 2>/dev/null; then
        echo "    ${agent}: done"
    else
        echo "    ${agent}: skipped (not reachable or already uninstalled)"
    fi
done

echo ""

# -----------------------------------------------------------------------------
# Uninstall K3s servers (HA control plane)
# -----------------------------------------------------------------------------
for server in "${SERVERS[@]}"; do
    echo "  Uninstalling K3s server on ${server}..."
    if ssh -o ConnectTimeout=10 "${SSH_USER}@${server}" \
        "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null; then
        echo "    ${server}: done"
    else
        echo "    ${server}: skipped (not reachable or already uninstalled)"
    fi
done

echo ""

# -----------------------------------------------------------------------------
# Clean up local kubeconfig
# -----------------------------------------------------------------------------
KUBECONFIG_PATH="${HOME}/.kube/config"

if [[ -f "$KUBECONFIG_PATH" ]]; then
    BACKUP="${KUBECONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    echo "  Backing up kubeconfig to ${BACKUP}"
    cp "$KUBECONFIG_PATH" "$BACKUP"
    rm "$KUBECONFIG_PATH"
    echo "  Removed ${KUBECONFIG_PATH}"
else
    echo "  No kubeconfig found at ${KUBECONFIG_PATH}, skipping."
fi

echo ""

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "  =================================================="
echo "    Cluster has been destroyed."
echo "  =================================================="
echo ""
echo "  To rebuild, run:"
echo "    make all"
echo ""
