#!/bin/bash
# Writes node_unit_active metrics for the node-exporter textfile collector.
# Runs from node-unit-health.timer every 60 s; deliberately does NOT log
# (its whole purpose is surviving a dead systemd-journald — the 2026-06-16
# incident where a node limped 18 days with journald down and nothing paged).
# Managed by Ansible (common / common-arch roles, task #59).
OUT=/var/lib/node_exporter/textfile/unit-health.prom
TMP="$OUT.tmp"
{
  echo "# HELP node_unit_active 1 if the systemd unit is active, 0 otherwise"
  echo "# TYPE node_unit_active gauge"
  for u in systemd-journald systemd-resolved tailscaled iscsid k3s k3s-agent; do
    if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q .; then
      v=0
      [ "$(systemctl is-active "$u.service" 2>/dev/null)" = "active" ] && v=1
      echo "node_unit_active{unit=\"$u\"} $v"
    fi
  done
} > "$TMP" && mv "$TMP" "$OUT"
exit 0
