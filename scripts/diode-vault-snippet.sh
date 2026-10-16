#!/usr/bin/env bash
# Print the live diode/orb secrets from the GPU node as vault.yml YAML, for a
# one-time import when bringing the hand-made diode stack under Ansible (#82).
# Prints secrets — pipe it straight to the clipboard, never into a log:
#
#   scripts/diode-vault-snippet.sh | pbcopy
#   ansible-vault edit ansible/inventory/group_vars/all/vault.yml   # paste, save
#   make diode CHECK=1
#
# Skips netbox_diode_client_secret (already in vault for playbook 24) but
# warns if the live value differs from it.
set -euo pipefail
HOST="${1:-minisforum-c}"
ssh "$HOST" 'python3 - <<"PY"
import json, os, subprocess
env = {}
for line in open(os.path.expanduser("~/diode/.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); env[k] = v
creds = {c["client_id"]: c["client_secret"]
         for c in json.load(open(os.path.expanduser("~/diode/oauth2/client/client-credentials.json")))}
community = ""
for line in open(os.path.expanduser("~/orb/agent.yaml")):
    if "community:" in line:
        community = line.split("community:", 1)[1].strip().strip("\"'"'"'")
        break
out = {
    "diode_redis_password": env["REDIS_PASSWORD"],
    "diode_postgres_password": env["POSTGRES_PASSWORD"],
    "diode_db_password": env["DIODE_POSTGRES_PASSWORD"],
    "diode_hydra_db_password": env["HYDRA_POSTGRES_PASSWORD"],
    "diode_hydra_secrets_system": env["HYDRA_SECRETS_SYSTEM_0"],
    "diode_ingest_client_secret": creds["diode-ingest"],
    "diode_to_netbox_client_secret": env["DIODE_TO_NETBOX_CLIENT_SECRET"],
    "orb_snmp_community": community,
}
assert creds["diode-to-netbox"] == env["DIODE_TO_NETBOX_CLIENT_SECRET"], "diode-to-netbox secret differs between .env and client-credentials.json"
print("# diode server + orb-agent (playbook 27) — imported from the live host")
for k, v in out.items():
    print(f"{k}: {json.dumps(v)}")
PY'
