#!/usr/bin/env bash
# alerts-digest.sh — "what has been paging while nobody was looking?"
#
# Three views, all read-only, each degrades to a one-line note if its source is
# unreachable (so the SessionStart hook never blocks):
#   1. Prometheus: alerts firing RIGHT NOW (Watchdog excluded)
#   2. Prometheus ALERTS history: everything that fired in the last WINDOW —
#      firing-minutes, distinct days (>=2 = RECURRING), last seen
#   3. Wazuh: rule level >= WAZUH_MIN_LEVEL alerts in the last WINDOW, grouped by
#      agent + rule, with count and last-seen (via `ssh wazuh` + the indexer admin
#      client cert — no password involved)
#
# Usage: scripts/alerts-digest.sh [--hook]     (--hook = prefix for the SessionStart banner)
# Env:   WINDOW=7d  WAZUH_MIN_LEVEL=10  PROM_URL=https://prometheus.<local_domain>
#
# Added 2026-09-10 after a recurring DefectDojo uwsgi OOM (Wazuh rule 5108, every
# other day for two weeks, ContainerOOMKilled firing each time) went unnoticed
# because the session bootstrap only surfaced the release-watcher digest.

set -uo pipefail
WINDOW="${WINDOW:-7d}"
WAZUH_MIN_LEVEL="${WAZUH_MIN_LEVEL:-10}"
LOCAL_DOMAIN="${LOCAL_DOMAIN:-$(grep -E '^local_domain:' "$(dirname "$0")/../ansible/inventory/group_vars/all/main.yml" 2>/dev/null | awk '{print $2}' | tr -d '"')}"
PROM_URL="${PROM_URL:-https://prometheus.${LOCAL_DOMAIN:-example.local}}"
HOOK=""; [[ "${1:-}" == "--hook" ]] && HOOK=1
WSEC=$(python3 -c "import re,sys; n,u=re.match(r'(\d+)([smhdw])','$WINDOW').groups(); print(int(n)*{'s':1,'m':60,'h':3600,'d':86400,'w':604800}[u])")

[[ -n "$HOOK" ]] && echo "Alerts digest (last $WINDOW) — report anything non-empty to the user in the bootstrap summary:"

# --- 1. firing now ------------------------------------------------------------
echo "== Firing now (Prometheus, Watchdog excluded) =="
if OUT=$(curl -sk --max-time 20 "$PROM_URL/api/v1/alerts" 2>/dev/null) && [[ -n "$OUT" ]]; then
  OUT="$OUT" python3 - <<'EOF'
import os, json
al = [a for a in json.loads(os.environ["OUT"])["data"]["alerts"] if a["state"] == "firing" and a["labels"]["alertname"] != "Watchdog"]
if not al: print("  none")
for a in sorted(al, key=lambda a: a["labels"]["alertname"]):
    l = a["labels"]; where = l.get("namespace", "") + "/" + l.get("pod", l.get("instance", ""))
    print(f"  {l.get('severity', '?'):8} {l['alertname']:36} {where:45} since {a['activeAt'][:16]}Z")
EOF
else
  echo "  (Prometheus unreachable at $PROM_URL)"
fi

# --- 2. fired in window (query_range at 5-min steps, computed client-side) --------
echo "== Fired in the last $WINDOW (firing-minutes · distinct days [>=2 = RECURRING] · last seen) =="
NOW=$(date +%s)
if OUT=$(curl -sk --max-time 30 "$PROM_URL/api/v1/query_range" \
      --data-urlencode 'query=max by (alertname,namespace,severity) (ALERTS{alertstate="firing",alertname!="Watchdog"})' \
      --data-urlencode "start=$((NOW - WSEC))" --data-urlencode "end=$NOW" --data-urlencode "step=300" 2>/dev/null) && [[ -n "$OUT" ]]; then
  OUT="$OUT" python3 - <<'EOF'
import os, json, datetime
res = json.loads(os.environ["OUT"])["data"]["result"]
if not res: print("  none")
rows = []
for r in res:
    ts = [t for t, _ in r["values"]]
    days = {datetime.datetime.utcfromtimestamp(t).date() for t in ts}
    rows.append((len(days), len(ts) * 5, max(ts), r["metric"]))
for nd, mins, last, l in sorted(rows, key=lambda x: (-x[0], -x[1])):
    flag = "RECURRING" if nd >= 2 else ""
    last_s = datetime.datetime.utcfromtimestamp(last).strftime("%m-%d %H:%MZ")
    print(f"  {l.get('severity', '?'):8} {l['alertname']:36} {l.get('namespace', ''):14} {mins:6d} min · {nd} day(s) · last {last_s} {flag}")
EOF
else
  echo "  (Prometheus unreachable)"
fi

# --- 3. Wazuh high-level alerts ----------------------------------------------
echo "== Wazuh alerts level >= $WAZUH_MIN_LEVEL in the last $WINDOW (count · last seen · level · agent · rule) =="
WQ='{"size":0,"query":{"bool":{"filter":[{"range":{"rule.level":{"gte":'"$WAZUH_MIN_LEVEL"'}}},{"range":{"timestamp":{"gte":"now-'"$WINDOW"'"}}}]}},"aggs":{"by":{"multi_terms":{"terms":[{"field":"agent.name"},{"field":"rule.id"}],"size":30,"order":{"_count":"desc"}},"aggs":{"last":{"max":{"field":"timestamp"}},"desc":{"terms":{"field":"rule.description","size":1}},"lvl":{"max":{"field":"rule.level"}},"days":{"cardinality":{"script":{"source":"doc[\"timestamp\"].value.toLocalDate().toString()"}}}}}}}'
if OUT=$(ssh -o ConnectTimeout=10 -o BatchMode=yes wazuh "sudo curl -sk --max-time 20 --cert /etc/wazuh-indexer/certs/admin.pem --key /etc/wazuh-indexer/certs/admin-key.pem -H 'Content-Type: application/json' 'https://127.0.0.1:9200/wazuh-alerts-*/_search' -d '$WQ'" 2>/dev/null) && [[ -n "$OUT" ]]; then
  OUT="$OUT" python3 - <<'EOF'
import os, json, datetime
d = json.loads(os.environ["OUT"])
b = d.get("aggregations", {}).get("by", {}).get("buckets", [])
if not b: print("  none" if "aggregations" in d else "  (query error: %s)" % str(d.get("error", d))[:160])
for x in b:
    agent, rid = x["key"]
    last = datetime.datetime.utcfromtimestamp(x["last"]["value"] / 1000).strftime("%m-%d %H:%MZ")
    desc = (x["desc"]["buckets"][0]["key"] if x["desc"]["buckets"] else "?")[:70]
    nd = x["days"]["value"]; flag = "RECURRING" if nd >= 2 else ""
    print(f"  {x['doc_count']:5d} · last {last} · {nd} day(s) · L{int(x['lvl']['value']):<2} {agent:14} #{rid:<6} {desc} {flag}")
EOF
else
  echo "  (Wazuh unreachable via ssh)"
fi
