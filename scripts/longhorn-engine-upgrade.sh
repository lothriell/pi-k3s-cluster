#!/usr/bin/env bash
# Live-upgrade every attached Longhorn volume's engine to the current default
# engine image, one volume at a time, health-gated (stop at the first volume
# that doesn't come back healthy on the new image).
#
# Run after a Longhorn Helm upgrade (`make longhorn`): the chart rolls the
# managers but leaves volumes on the old engine until spec.image is patched.
# Done by hand v1.12.0->v1.12.1 (2026-08-22); scripted for v1.13.0 (2026-10-15).
#
# Usage: scripts/longhorn-engine-upgrade.sh [--dry-run]
# Env:   TIMEOUT=180 (seconds per volume)
set -euo pipefail

NS=longhorn-system
TIMEOUT="${TIMEOUT:-180}"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

TARGET=$(kubectl -n "$NS" get settings.longhorn.io default-engine-image -o jsonpath='{.value}')
[[ -n "$TARGET" ]] || { echo "no default-engine-image setting" >&2; exit 1; }
echo "Target engine image: $TARGET"

state=$(kubectl -n "$NS" get engineimages.longhorn.io -o json \
  | jq -r --arg t "$TARGET" '.items[]|select(.spec.image==$t)|.status.state')
[[ "$state" == "deployed" ]] || { echo "engine image not deployed yet (state='$state')" >&2; exit 1; }

# while-read, not mapfile: macOS ships bash 3.2.
VOLS=()
while IFS= read -r l; do VOLS+=("$l"); done < <(kubectl -n "$NS" get volumes.longhorn.io -o json \
  | jq -r --arg t "$TARGET" \
  '.items[]|select(.status.currentImage!=$t)|"\(.metadata.name) \(.status.state) \(.status.robustness)"')
echo "${#VOLS[@]} volume(s) to upgrade"
# bash 3.2 + set -u treats an empty array as unbound.
(( ${#VOLS[@]} )) || { echo "Nothing to do."; exit 0; }

for line in "${VOLS[@]}"; do
  read -r vol st rob <<<"$line"
  if [[ "$st" == "attached" && "$rob" != "healthy" ]]; then
    echo "ABORT: $vol is $st/$rob — fix it before upgrading further" >&2; exit 1
  fi
  if (( DRY )); then echo "would upgrade $vol ($st/$rob)"; continue; fi
  start=$(date +%s)
  kubectl -n "$NS" patch volumes.longhorn.io "$vol" --type merge -p "{\"spec\":{\"image\":\"$TARGET\"}}" >/dev/null
  # Detached volumes just take the new spec.image; they switch on next attach.
  [[ "$st" != "attached" ]] && { echo "  $vol: detached, spec.image set"; continue; }
  until read -r cur r < <(kubectl -n "$NS" get volumes.longhorn.io "$vol" \
          -o jsonpath='{.status.currentImage} {.status.robustness}'); \
        [[ "$cur" == "$TARGET" && "$r" == "healthy" ]]; do
    (( $(date +%s) - start > TIMEOUT )) && { echo "ABORT: $vol not healthy on $TARGET after ${TIMEOUT}s (cur=$cur robustness=$r)" >&2; exit 1; }
    sleep 3
  done
  echo "  $vol: ok in $(( $(date +%s) - start ))s"
done

echo "Done. Old EngineImage CRs (refCount 0 once all volumes moved):"
kubectl -n "$NS" get engineimages.longhorn.io
