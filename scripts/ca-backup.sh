#!/usr/bin/env bash
# Capture the live homielab internal CA into vault.yml.
#
# Why: cert-manager's homielab-ca-tls Secret is the only place the CA's
# private key lives by default. A `make nuke` + rebuild would generate a
# new root, breaking trust on every device until they re-import. Stashing
# the cert+key in vault.yml lets `make cert-manager` (playbook 17) pre-seed
# the same secret and skip regeneration on rebuild.
#
# Usage:
#   make ca-backup
#
# Idempotent: replaces any existing homielab_ca_cert / homielab_ca_key
# entries in vault.yml. Always works against the LIVE cluster's secret —
# whatever cert-manager shows is what gets stored.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
VAULT="$REPO_ROOT/ansible/inventory/group_vars/all/vault.yml"
NS=cert-manager
SECRET=homielab-ca-tls

if [ ! -f "$VAULT" ]; then
  echo "ERROR: $VAULT not found. Did you copy vault.yml.example yet?" >&2
  exit 1
fi

if ! kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  echo "ERROR: Secret $NS/$SECRET not found. Run 'make cert-manager' first." >&2
  exit 1
fi

# Extract from cluster
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TMP/ca.crt"
kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.tls\.key}' | base64 -d > "$TMP/ca.key"

FP=$(openssl x509 -noout -fingerprint -sha256 -in "$TMP/ca.crt" | awk -F'=' '{print $2}')
SUBJ=$(openssl x509 -noout -subject -in "$TMP/ca.crt" | sed 's/^subject= *//')
NOTAFTER=$(openssl x509 -noout -enddate -in "$TMP/ca.crt" | sed 's/^notAfter=//')

echo "Live CA:"
echo "  subject:    $SUBJ"
echo "  notAfter:   $NOTAFTER"
echo "  fingerprint: $FP"

# Decrypt vault, strip any existing CA stanza, re-append, re-encrypt.
ansible-vault decrypt --output "$TMP/vault.yml" "$VAULT"

# Drop existing homielab_ca_cert / homielab_ca_key blocks and the comment block.
python3 - "$TMP/vault.yml" "$TMP/vault.stripped.yml" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# Remove the header comment + both block-literal vars (until next top-level key
# or EOF). We match on lines starting with `homielab_ca_cert:` or
# `homielab_ca_key:` and strip until the next non-indented, non-blank line.
lines = text.splitlines(keepends=True)
out, skip = [], False
for ln in lines:
    stripped = ln.lstrip()
    if ln.startswith('# homielab internal CA'):
        skip = True
        continue
    if ln.startswith('homielab_ca_cert:') or ln.startswith('homielab_ca_key:'):
        skip = True
        continue
    if skip:
        # End the skip when a new top-level key starts (no leading whitespace)
        if ln and not ln[0].isspace() and not ln.startswith('#'):
            skip = False
            out.append(ln)
        continue
    out.append(ln)
# Trim trailing blank lines
while out and out[-1].strip() == '':
    out.pop()
out.append('\n')
open(dst, 'w').writelines(out)
PY

# Append fresh CA block
{
  echo
  echo "# homielab internal CA — backup of cert-manager/homielab-ca-tls so a"
  echo "# cluster rebuild can restore the SAME root and not force every device"
  echo "# to re-import. Pre-seeded by make cert-manager (playbook 17)."
  echo "# Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "#   subject:     $SUBJ"
  echo "#   notAfter:    $NOTAFTER"
  echo "#   fingerprint: $FP"
  echo "homielab_ca_cert: |"
  sed 's/^/  /' "$TMP/ca.crt"
  echo "homielab_ca_key: |"
  sed 's/^/  /' "$TMP/ca.key"
} >> "$TMP/vault.stripped.yml"

ansible-vault encrypt --output "$VAULT" "$TMP/vault.stripped.yml"
echo
echo "Updated $VAULT — verify with:"
echo "  ansible-vault view $VAULT | tail -25"
