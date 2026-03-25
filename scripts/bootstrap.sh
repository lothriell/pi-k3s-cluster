#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Raspberry Pi CM5 K3s Cluster - Bootstrap Script
# =============================================================================

# Node list (adjust to match your network)
NODES=("rpi-k3s-1" "rpi-k3s-2" "rpi-k3s-3" "rpi-k3s-4")
SSH_USER="ansible"

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
echo ""
echo "  =================================================="
echo "    Raspberry Pi CM5 K3s Cluster - Bootstrap"
echo "  =================================================="
echo ""
echo "  This script will:"
echo "    1. Verify prerequisites are installed"
echo "    2. Test SSH connectivity to all nodes"
echo "    3. Run the full cluster build (make all)"
echo ""

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------
echo "--- Checking prerequisites ---"
echo ""

MISSING=()

for cmd in ansible ansible-playbook kubectl helm k9s; do
    if command -v "$cmd" &>/dev/null; then
        version=$("$cmd" --version 2>&1 | head -n1)
        printf "  %-20s %s\n" "$cmd" "$version"
    else
        printf "  %-20s MISSING\n" "$cmd"
        MISSING+=("$cmd")
    fi
done

echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${MISSING[*]}"
    echo ""
    echo "Install them before continuing:"
    echo "  brew install ansible kubectl helm k9s"
    echo ""
    exit 1
fi

echo "All prerequisites found."
echo ""

# -----------------------------------------------------------------------------
# SSH Connectivity
# -----------------------------------------------------------------------------
echo "--- Testing SSH connectivity ---"
echo ""

FAILED_NODES=()

for node in "${NODES[@]}"; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_USER}@${node}" "echo ok" &>/dev/null; then
        printf "  %-20s OK\n" "$node"
    else
        printf "  %-20s FAILED\n" "$node"
        FAILED_NODES+=("$node")
    fi
done

echo ""

if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
    echo "ERROR: Cannot reach nodes: ${FAILED_NODES[*]}"
    echo ""
    echo "Verify that:"
    echo "  - Nodes are powered on and connected to the network"
    echo "  - SSH keys are installed (ssh-copy-id ${SSH_USER}@<node>)"
    echo "  - Hostnames resolve (check /etc/hosts or DNS)"
    echo ""
    exit 1
fi

echo "All nodes reachable."
echo ""

# -----------------------------------------------------------------------------
# Run Full Build
# -----------------------------------------------------------------------------
echo "--- Starting full cluster build ---"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

make -C "$PROJECT_DIR" all

echo ""

# -----------------------------------------------------------------------------
# Final Status
# -----------------------------------------------------------------------------
echo "--- Cluster Status ---"
echo ""

make -C "$PROJECT_DIR" status

echo ""
echo "  =================================================="
echo "    Bootstrap complete!"
echo "  =================================================="
echo ""
echo "  Next steps:"
echo "    make status          - Check cluster health"
echo "    make cert-manager    - Set up TLS certificates"
echo "    make cloudflare      - Enable external access"
echo "    k9s                  - Launch the cluster TUI"
echo ""
