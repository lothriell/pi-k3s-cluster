#!/usr/bin/env bash
# Fleet Tailscale audit: the RUNNING daemon version on every inventory host
# (plus this Mac) against the latest stable release.
#
# Daemon, not CLI: on the Macs `brew upgrade tailscale` updates only the CLI
# while the LaunchDaemon keeps running the copy install-system-daemon made
# (2026-10-27: CLI 1.104.x, daemons 1.96.4 / 1.98.5). Mac fix:
#   make mac-upgrade   (playbook 80 phases 5/5b: brew + install-system-daemon via the ansible account)
# Linux fix: apt/pacman upgrade (playbook 80), or for a quick pass:
#   ansible <hosts> -b -m apt -a "name=tailscale state=latest update_cache=yes only_upgrade=yes"
#
# Usage: scripts/tailscale-versions.sh   (make tailscale-versions)
set -uo pipefail
cd "$(dirname "$0")/.."

latest=$(curl -sf --max-time 20 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.TarballsVersion // empty')
echo "latest stable: ${latest:-unknown}"

# Top-level "Version" of `tailscale status --json` is the daemon's.
probe='PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; tailscale status --json 2>/dev/null | sed -n "s/^[[:space:]]*\"Version\": \"\([0-9.]*\).*/\1/p" | head -1'

{
  ansible all -m shell -a "$probe" -o 2>/dev/null \
    | awk '/UNREACHABLE/ {print $1, "unreachable"; next}
           /\| (CHANGED|SUCCESS)/ {v=$NF; if (v ~ /^[0-9.]+$/) print $1, v; else print $1, "no-tailscale"; next}
           /\| FAILED/ {print $1, "no-tailscale"}'
  echo "$(hostname -s)(local) $(eval "$probe")"
} | sort -u | while read -r host ver; do
  flag=""
  [[ "$ver" =~ ^[0-9.]+$ && -n "$latest" && "$ver" != "$latest" ]] && flag="  <-- behind"
  printf '%-22s %s%s\n' "$host" "$ver" "$flag"
done
