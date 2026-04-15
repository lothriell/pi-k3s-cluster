#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# K3s Cluster - Nuke Script  (HA topology, Tailscale-safe)
# =============================================================================
#
# 2026-04-15 incident: the previous version SSH'd via bare hostnames (e.g.
# `rpi-k3s-1`), which the Mac resolved via the Tailscale subnet route
# advertised from the K3s server itself. When k3s-uninstall.sh ran on that
# server it flushed iptables + killed containerd + dropped CNI interfaces,
# which broke the subnet route and severed this script's own SSH connection
# mid-uninstall. The Pi ended up half-uninstalled (service stopped, uninstall
# script deleted, binary + state remaining) and the remaining 3 Pi SSH
# attempts timed out because the subnet route was gone with the cluster.
#
# Two-part fix:
#   1. Target each Pi by its *direct* tailnet IP (100.x) queried at runtime
#      from `tailscale status --json`. Direct tailnet connections route
#      node-to-node over WireGuard and survive subnet-route disruption.
#      x86 nodes use their existing ~/.ssh/config aliases (ProxyJump via
#      macmini). See reference_ssh_routing memory.
#   2. Launch the uninstall detached via `nohup ... &` so the SSH session
#      returns immediately. The local uninstall completes even if the
#      remote node's network briefly disappears.
#
# After kicking off all nukes, the script polls each node until the k3s
# binary is gone or a timeout expires.
# =============================================================================

# K3s HA topology (logical names — matches Ansible inventory)
SERVERS=("rpi-k3s-1" "rpi-k3s-2" "rpi-k3s-3")
AGENTS=("rpi-k3s-4" "k3s-x86-1" "k3s-x86-2")
SSH_USER="ansible"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
UNINSTALL_TIMEOUT_S=240

# -----------------------------------------------------------------------------
# resolve_target: given a logical node name, return an SSH target string.
# - x86 nodes + macmini have ~/.ssh/config aliases → just return the name.
# - Pi nodes have no alias → look up the tailnet IP via `tailscale status`.
#   Handles the `-N` hostname-collision suffix Tailscale adds automatically.
# -----------------------------------------------------------------------------
resolve_target() {
    local name="$1"

    # If ssh -G reports a non-identity hostname mapping, there's a Host alias
    # for this name in ~/.ssh/config. Use it as-is.
    if ssh -G "$name" 2>/dev/null | awk -v n="$name" '$1=="hostname" && $2!=n {found=1} END {exit !found}'; then
        echo "$name"
        return
    fi

    # Fall back to tailscale CLI lookup (requires tailscaled running on this host).
    if command -v tailscale >/dev/null 2>&1; then
        local ts_ip
        ts_ip=$(tailscale status --json 2>/dev/null | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
want = sys.argv[1]
# Match exact name or name with a numeric -N collision suffix
pattern = re.compile(rf'^{re.escape(want)}(-\d+)?$')
for p in d.get('Peer', {}).values():
    host = p.get('HostName', '')
    if pattern.match(host):
        ips = p.get('TailscaleIPs', [])
        if ips:
            print(ips[0])
            sys.exit(0)
sys.exit(1)
" "$name" 2>/dev/null) || ts_ip=""
        if [ -n "$ts_ip" ]; then
            echo "$ts_ip"
            return
        fi
    fi

    # Last resort: return the bare name and hope SSH resolves it somehow.
    echo "$name"
}

# -----------------------------------------------------------------------------
# nuke_node: launch uninstall detached on a remote node, return immediately.
# $1 = logical node name, $2 = "agent" or "server"
# -----------------------------------------------------------------------------
nuke_node() {
    local name="$1" kind="$2"
    local target script
    target=$(resolve_target "$name")
    if [ "$kind" = "agent" ]; then
        script="/usr/local/bin/k3s-agent-uninstall.sh"
    else
        script="/usr/local/bin/k3s-uninstall.sh"
    fi

    printf "  %s (%s → %s): " "$name" "$kind" "$target"
    if ssh $SSH_OPTS "${SSH_USER}@${target}" "
        if [ -x $script ]; then
            sudo bash -c 'nohup $script >/tmp/k3s-uninstall.log 2>&1 </dev/null &'
            echo detach-ok
        elif [ ! -e /usr/local/bin/k3s ]; then
            echo already-clean
        else
            echo partial-state
        fi
    " 2>/dev/null; then
        :
    else
        echo "unreachable (skipped)"
    fi
}

# -----------------------------------------------------------------------------
# wait_for_clean: poll until /usr/local/bin/k3s is gone on the node.
# -----------------------------------------------------------------------------
wait_for_clean() {
    local name="$1"
    local target; target=$(resolve_target "$name")
    local elapsed=0
    while [ $elapsed -lt $UNINSTALL_TIMEOUT_S ]; do
        if ssh $SSH_OPTS "${SSH_USER}@${target}" 'test ! -e /usr/local/bin/k3s' 2>/dev/null; then
            echo "  $name: clean"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "  $name: NOT clean after ${UNINSTALL_TIMEOUT_S}s — manual cleanup may be needed"
    return 1
}

# -----------------------------------------------------------------------------
# Warning banner + confirmation
# -----------------------------------------------------------------------------
echo ""
echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  !                                                !"
echo "  !          CLUSTER DESTRUCTION SCRIPT            !"
echo "  !                                                !"
echo "  !  This will PERMANENTLY DESTROY the K3s         !"
echo "  !  cluster and ALL workloads running on it.      !"
echo "  !                                                !"
echo "  !  Actions performed (each in parallel):         !"
echo "  !    - Detach-launch k3s[-agent]-uninstall.sh    !"
echo "  !    - Poll until /usr/local/bin/k3s is gone     !"
echo "  !    - Back up and remove local kubeconfig       !"
echo "  !                                                !"
echo "  !  Longhorn data at /var/lib/longhorn is NOT     !"
echo "  !  touched; restore happens from R2 via          !"
echo "  !  'make restore-volumes' after 'make all'.      !"
echo "  !                                                !"
echo "  !  THIS CANNOT BE UNDONE.                        !"
echo "  !                                                !"
echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""
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
# Launch detached uninstalls on agents first, then servers
# -----------------------------------------------------------------------------
echo "Launching agent uninstalls..."
for agent in "${AGENTS[@]}"; do
    nuke_node "$agent" agent
done

echo ""
echo "Launching server uninstalls..."
for server in "${SERVERS[@]}"; do
    nuke_node "$server" server
done

# -----------------------------------------------------------------------------
# Poll for completion
# -----------------------------------------------------------------------------
echo ""
echo "Waiting for uninstalls to finish (timeout ${UNINSTALL_TIMEOUT_S}s per node)..."
echo ""

FAILED=()
for node in "${AGENTS[@]}" "${SERVERS[@]}"; do
    if ! wait_for_clean "$node"; then
        FAILED+=("$node")
    fi
done

# -----------------------------------------------------------------------------
# Local kubeconfig cleanup
# -----------------------------------------------------------------------------
echo ""
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
echo "  =================================================="
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "    Cluster has been destroyed cleanly."
else
    echo "    Cluster destroyed but these nodes need manual cleanup:"
    for n in "${FAILED[@]}"; do echo "      - $n"; done
fi
echo "  =================================================="
echo ""
echo "  To rebuild, run:"
echo "    make all"
echo ""
