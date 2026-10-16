#!/usr/bin/env bash
# Get a node drain past Longhorn single-replica volumes (#82).
#
# A numberOfReplicas=1 volume (the prometheus-server TSDB, see
# single_replica_pvcs in 11-configure-backups.yml) whose only replica sits on
# the node being drained keeps that node's instance-manager PDB at 0 allowed
# disruptions under node-drain-policy=block-if-contains-last-replica — the
# drain retries forever (2026-10-16: minisforum-c hung 4h16m). Detaching the
# volume alone is not enough; a stopped last replica still blocks.
#
#   pre NODE   scale the owning Deployment/StatefulSet of every such volume to
#              0 (original count kept in an annotation), wait for detach, then
#              relax node-drain-policy to allow-if-replica-is-stopped
#              (original value kept in an annotation on the setting).
#   post       restore the policy and scale every annotated workload back.
#              Cluster-wide and idempotent — also the manual recovery after an
#              aborted run.
#   check NODE list what `pre` would do.
#
# State lives on the cluster objects, not in the caller, so a playbook abort
# between pre and post loses nothing: run `post` again.
set -euo pipefail

NS=longhorn-system
ANN=longhorn-drain-guard/replicas
POLICY_ANN=longhorn-drain-guard/original
TIMEOUT="${TIMEOUT:-300}"

usage() { echo "usage: $0 pre|check NODE | post" >&2; exit 2; }

# "<volume> <state> <namespace> <pvcName>" for every 1-replica volume with a
# replica on $1.
single_replica_vols() {
  local reps
  reps=$(kubectl -n "$NS" get replicas.longhorn.io -o json \
    | jq -r --arg n "$1" '.items[]|select(.spec.nodeID==$n)|.spec.volumeName' | sort -u)
  [[ -n "$reps" ]] || return 0
  kubectl -n "$NS" get volumes.longhorn.io -o json \
    | jq -r --arg v "$reps" '($v|split("\n")) as $on
        | .items[] | select(.spec.numberOfReplicas==1) | select(.metadata.name | IN($on[]))
        | [.metadata.name, .status.state,
           (.status.kubernetesStatus.namespace // "-"),
           (.status.kubernetesStatus.pvcName // "-")] | join(" ")'
}

# Name of a live pod in ns $1 mounting PVC $2. Longhorn's own
# kubernetesStatus.workloadsStatus podName goes stale once the pod is replaced.
pod_using() {
  kubectl -n "$1" get pods -o json | jq -r --arg c "$2" \
    '[.items[]|select(.status.phase!="Succeeded" and .status.phase!="Failed")
      |select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName==$c))|.metadata.name][0] // empty'
}

# "<kind>/<name>" of the Deployment/StatefulSet that owns pod $2 in ns $1.
owner_of() {
  local ns=$1 pod=$2 kind name
  [[ -n "$pod" ]] || return 1
  # jsonpath output has no trailing newline: read hits EOF and returns 1, so
  # don't let that status through.
  read -r kind name < <(kubectl -n "$ns" get pod "$pod" \
    -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.ownerReferences[0].name}' 2>/dev/null) || true
  if [[ "$kind" == "ReplicaSet" ]]; then
    read -r kind name < <(kubectl -n "$ns" get rs "$name" \
      -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.ownerReferences[0].name}') || true
  fi
  case "$kind" in Deployment|StatefulSet) echo "$(tr '[:upper:]' '[:lower:]' <<<"$kind")/$name" ;; *) return 1 ;; esac
}

pre() {
  local node=$1 dry=${2:-0} lines=() line vol st ns pvc pod wl n start
  while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done < <(single_replica_vols "$node")
  # bash 3.2 + set -u treats an empty array as unbound.
  (( ${#lines[@]} )) || { echo "no single-replica volumes on $node"; return 0; }

  for line in "${lines[@]}"; do
    read -r vol st ns pvc <<<"$line"
    if [[ "$st" != "attached" ]]; then echo "$vol: already $st"; continue; fi
    pod=$(pod_using "$ns" "$pvc")
    wl=$(owner_of "$ns" "$pod") || { echo "ABORT: $vol ($ns/$pvc) attached but no Deployment/StatefulSet owner found (pod='$pod')" >&2; exit 1; }
    n=$(kubectl -n "$ns" get "$wl" -o jsonpath='{.spec.replicas}')
    if (( dry )); then echo "would scale $ns/$wl $n->0 (holds $vol)"; continue; fi
    kubectl -n "$ns" annotate "$wl" --overwrite "$ANN=$n" >/dev/null
    kubectl -n "$ns" scale "$wl" --replicas=0 >/dev/null
    echo "$vol: scaled $ns/$wl $n->0"
    start=$(date +%s)
    until [[ "$(kubectl -n "$NS" get volumes.longhorn.io "$vol" -o jsonpath='{.status.state}')" == "detached" ]]; do
      (( $(date +%s) - start > TIMEOUT )) && { echo "ABORT: $vol not detached after ${TIMEOUT}s — run '$0 post' to restore" >&2; exit 1; }
      sleep 3
    done
    echo "$vol: detached"
  done

  local cur
  cur=$(kubectl -n "$NS" get settings.longhorn.io node-drain-policy -o jsonpath='{.value}')
  if (( dry )); then echo "would set node-drain-policy $cur->allow-if-replica-is-stopped"; return 0; fi
  if [[ "$cur" != "allow-if-replica-is-stopped" ]]; then
    kubectl -n "$NS" annotate settings.longhorn.io node-drain-policy --overwrite "$POLICY_ANN=$cur" >/dev/null
    kubectl -n "$NS" patch settings.longhorn.io node-drain-policy --type merge -p '{"value":"allow-if-replica-is-stopped"}' >/dev/null
    echo "node-drain-policy: $cur -> allow-if-replica-is-stopped"
  fi
}

post() {
  local orig line ns wl n
  orig=$(kubectl -n "$NS" get settings.longhorn.io node-drain-policy -o json | jq -r --arg a "$POLICY_ANN" '.metadata.annotations[$a] // empty')
  if [[ -n "$orig" ]]; then
    kubectl -n "$NS" patch settings.longhorn.io node-drain-policy --type merge -p "{\"value\":\"$orig\"}" >/dev/null
    kubectl -n "$NS" annotate settings.longhorn.io node-drain-policy "$POLICY_ANN-" >/dev/null
    echo "node-drain-policy restored to $orig"
  fi
  while read -r ns wl n; do
    [[ -n "$ns" ]] || continue
    kubectl -n "$ns" scale "$wl" --replicas="$n" >/dev/null
    kubectl -n "$ns" annotate "$wl" "$ANN-" >/dev/null
    echo "scaled $ns/$wl back to $n"
  done < <(kubectl get deploy,sts -A -o json | jq -r --arg a "$ANN" \
    '.items[]|select(.metadata.annotations[$a])|"\(.metadata.namespace) \(.kind|ascii_downcase)/\(.metadata.name) \(.metadata.annotations[$a])"')
}

case "${1:-}" in
  pre)   [[ -n "${2:-}" ]] || usage; pre "$2" ;;
  check) [[ -n "${2:-}" ]] || usage; pre "$2" 1 ;;
  post)  post ;;
  *)     usage ;;
esac
