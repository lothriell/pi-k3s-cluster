#!/usr/bin/env bash
# k3s-upgrade.sh — serial, health-gated in-place K3s upgrade of the whole cluster.
#
# Usage:  scripts/k3s-upgrade.sh v1.36.4+k3s1 [--skip-snapshot] [--check]
#         --check  = pre-flight + leader + per-server args only, no snapshot, no upgrade
#
# Procedure (codified from the 2026-07-26 and 2026-08-11 manual upgrades):
#   0. Pre-flight: every agent owns `server:` + `token:` in /etc/rancher/k3s/config.yaml
#      (the install script wipes k3s-agent.service.env — CLAUDE.md "Agent Token Loss").
#   1. Pre-upgrade etcd snapshot on the CURRENT LEADER (only one server at a time —
#      snapshot I/O on Pi eMMC can cost a lease if two run together).
#   2. Servers, serial, non-leaders first, leader last. The get.k3s.io script is re-run
#      with the node's CURRENT systemd ExecStart args (it rewrites the unit, so the args
#      must be re-passed verbatim). Gate between hops: kubelet VERSION column flips
#      (node Ready alone passes before the restart even happens), local /readyz = ok,
#      etcd_server_has_leader=1 on all three servers.
#   3. Agents, serial. No drain: an agent restart does not touch running containers.
#      Gate: version flips + node Ready.
#
# Runs from the workstation; per-node commands go through `ansible -b` (the `ansible`
# service account has passwordless sudo). Minor-version hops must be done one at a time
# (v1.35 -> v1.36 -> ...), never skipped — run this script once per hop.
#
# Afterwards: update `k3s_version` in ansible/inventory/hosts.yml.

set -euo pipefail

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <k3s version, e.g. v1.36.4+k3s1> [--skip-snapshot]" >&2; exit 2; }
SKIP_SNAPSHOT=""; CHECK_ONLY=""
for opt in "${@:2}"; do
  case "$opt" in
    --skip-snapshot) SKIP_SNAPSHOT=1 ;;
    --check) CHECK_ONLY=1 ;;
    *) echo "unknown option: $opt" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

SERVERS=(rpi-k3s-1 rpi-k3s-2 rpi-k3s-3)
AGENTS=(rpi-k3s-4 minisforum-c k3s-x86-1 k3s-x86-2)
GATE_TIMEOUT=300

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# Run a shell command on a host as root via ansible; print only the command's stdout.
remote() {
  local host="$1"; shift
  ansible "$host" -b -m shell -a "$*" 2>/dev/null \
    | sed -E -e '/^[^ ]+ \| (CHANGED|SUCCESS|FAILED)[^>]*>>$/d' -e '/^\[WARNING\]/d'
}

node_version() { kubectl get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true; }
node_ready()   { kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true; }

etcd_metric() { remote "$1" "curl -s http://127.0.0.1:2381/metrics | awk '/^$2 /{print \$2}'" | tr -d '[:space:]'; }

etcd_leader() {
  for s in "${SERVERS[@]}"; do
    [[ "$(etcd_metric "$s" etcd_server_is_leader)" == "1" ]] && { echo "$s"; return; }
  done
  echo ""
}

all_have_leader() {
  for s in "${SERVERS[@]}"; do
    [[ "$(etcd_metric "$s" etcd_server_has_leader)" == "1" ]] || return 1
  done
}

wait_for() {  # wait_for <desc> <cmd...>
  local desc="$1"; shift
  local deadline=$((SECONDS + GATE_TIMEOUT))
  until "$@"; do
    (( SECONDS < deadline )) || { log "TIMEOUT waiting for $desc"; exit 1; }
    sleep 5
  done
}

# Predicates for wait_for — must be functions, not `test "$(...)"`: a command substitution
# in the wait_for argument list is expanded ONCE at call time and would never re-evaluate.
version_is_target() { [[ "$(node_version "$1")" == "$TARGET" ]]; }
node_is_ready()     { [[ "$(node_ready "$1")" == "True" ]]; }
readyz_ok()         { [[ "$(remote "$1" 'k3s kubectl get --raw /readyz' | tr -d '[:space:]')" == "ok" ]]; }

gate_node() {  # gate_node <node> — version flipped + Ready
  local n="$1"
  wait_for "$n version flip" version_is_target "$n"
  wait_for "$n Ready" node_is_ready "$n"
}

gate_server() {
  local s="$1"
  gate_node "$s"
  wait_for "$s /readyz" readyz_ok "$s"
  wait_for "etcd has_leader on all servers" all_have_leader
}

server_args() {  # the exact args the unit currently runs with (everything after "server")
  remote "$1" "sed -n '/^ExecStart=/,\$p' /etc/systemd/system/k3s.service | tr -d '\\\\\\n\\t' | sed -e 's/  */ /g' -e 's/^ExecStart=[^ ]* server //'" \
    | tr -d "'" | sed 's/ *$//'
}

upgrade_server() {
  local s="$1"
  local args
  args="$(server_args "$s")"
  log "server $s: args = [$args]"
  remote "$s" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$TARGET' sh -s - server $args" | tail -3
  gate_server "$s"
  log "server $s: $(node_version "$s") Ready, /readyz ok, etcd quorum ok"
}

upgrade_agent() {
  local a="$1"
  # No K3S_URL/K3S_TOKEN env: join creds live in config.yaml (pre-flight checked).
  remote "$a" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$TARGET' sh -s - agent" | tail -3
  gate_node "$a"
  log "agent $a: $(node_version "$a") Ready"
}

# ---------------------------------------------------------------------------
START=$SECONDS
log "K3s upgrade to $TARGET — current: $(kubectl get nodes --no-headers | awk '{print $5}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"

log "pre-flight: agents own join creds in config.yaml"
for a in "${AGENTS[@]}"; do
  c="$(remote "$a" "grep -cE '^(server|token):' /etc/rancher/k3s/config.yaml" | tr -d '[:space:]')"
  [[ "$c" == "2" ]] || { log "ABORT: $a config.yaml has $c of 2 join lines (server:/token:) — token-loss trap live"; exit 1; }
done
log "pre-flight OK"

leader="$(etcd_leader)"
[[ -n "$leader" ]] || { log "ABORT: no etcd leader found"; exit 1; }
log "etcd leader: $leader"

if [[ -n "$CHECK_ONLY" ]]; then
  for s in "${SERVERS[@]}"; do
    log "$s: $(node_version "$s") ready=$(node_ready "$s") readyz=$(remote "$s" 'k3s kubectl get --raw /readyz' | tr -d '[:space:]') has_leader=$(etcd_metric "$s" etcd_server_has_leader) args=[$(server_args "$s")]"
  done
  for a in "${AGENTS[@]}"; do log "$a: $(node_version "$a") ready=$(node_ready "$a")"; done
  log "check only — exiting"; exit 0
fi

if [[ -z "$SKIP_SNAPSHOT" ]]; then
  snap="pre-upgrade-${TARGET//+/-}"   # e.g. pre-upgrade-v1.36.4-k3s1
  log "etcd snapshot '$snap' on $leader (only one server at a time)"
  remote "$leader" "k3s etcd-snapshot save --name '$snap' 2>&1 | tail -2"
  wait_for "etcd quorum after snapshot" all_have_leader
fi

# Servers: non-leaders first, leader last.
order=()
for s in "${SERVERS[@]}"; do [[ "$s" != "$leader" ]] && order+=("$s"); done
order+=("$leader")
for s in "${order[@]}"; do
  if [[ "$(node_version "$s")" == "$TARGET" ]]; then log "server $s already $TARGET, skipping"; continue; fi
  upgrade_server "$s"
done
log "servers done; etcd leader now: $(etcd_leader)"

for a in "${AGENTS[@]}"; do
  if [[ "$(node_version "$a")" == "$TARGET" ]]; then log "agent $a already $TARGET, skipping"; continue; fi
  upgrade_agent "$a"
done

# K3s re-deploys its packaged coredns.yaml when the manifest changes with the version,
# which reverts the home-zone placement patch (k8s/coredns/coredns-placement-patch.yml).
# Re-apply it — idempotent, "(no change)" when the packaged manifest didn't move.
log "re-applying CoreDNS placement patch (2 replicas, zone=home)"
kubectl -n kube-system patch deployment coredns \
  --patch-file "$(dirname "$0")/../k8s/coredns/coredns-placement-patch.yml"
kubectl -n kube-system rollout status deployment coredns --timeout=180s

log "DONE in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
kubectl get nodes
echo "Reminder: set k3s_version: \"$TARGET\" in ansible/inventory/hosts.yml"
