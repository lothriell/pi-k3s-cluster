#!/usr/bin/env bash
# Alertmanager silences for planned maintenance (reboot windows in playbooks
# 80/81). Both k3s-x86 nodes are VMs on pve-1, so a host reboot looks exactly
# like a Site Magic drop (RemoteSiteLinkDown/NodeDown/KubeNodeNotReady pages,
# then RemoteSiteLinkFlapping for 6h — 2026-10-19 PVE 9 upgrade); serial
# server reboots trip EtcdLeaderChanges (2026-10-15 fleet upgrade).
#
#   add TAG DURATION MATCHER...  silence the matchers (amtool syntax, ANDed)
#                                for DURATION, comment "maint:TAG"; prints the ID.
#                                DURATION is the safety cap: an aborted run
#                                un-silences on its own.
#   expire TAG                   expire every active silence tagged TAG.
#                                Idempotent — also the manual cleanup.
#   list                         active maint:* silences.
#
# Runs amtool inside the Alertmanager pod, so it needs only kubectl.
set -euo pipefail

NS=monitoring
POD="${ALERTMANAGER_POD:-prometheus-alertmanager-0}"

usage() { echo "usage: $0 add TAG DURATION MATCHER... | expire TAG | list" >&2; exit 2; }

amtool() {
  kubectl -n "$NS" exec "$POD" -c alertmanager -- \
    amtool --alertmanager.url=http://localhost:9093 "$@"
}

active() {
  amtool silence query -o json \
    | jq -r --arg c "${1:-}" '.[] | select(.status.state=="active")
        | select(if $c == "" then (.comment | startswith("maint:")) else .comment == $c end)
        | "\(.id) \(.endsAt) \(.comment) \([.matchers[] | "\(.name)\(if .isRegex then "=~" else "=" end)\(.value)"] | join(","))"'
}

case "${1:-}" in
  add)
    [[ $# -ge 4 ]] || usage
    tag=$2 dur=$3; shift 3
    amtool silence add -a ansible -c "maint:$tag" -d "$dur" "$@"
    ;;
  expire)
    [[ $# -eq 2 ]] || usage
    ids=$(active "maint:$2" | awk '{print $1}')
    [[ -n "$ids" ]] || exit 0
    # shellcheck disable=SC2086
    amtool silence expire $ids
    echo "expired: $(echo $ids)"
    ;;
  list)
    active
    ;;
  *) usage ;;
esac
