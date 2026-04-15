# Longhorn recovery runbook

Five PVCs hold state that must survive a cluster rebuild: Gitea (SQLite DB + repos + LFS), Grafana (dashboards + users + datasources), EVE tracker prod, EVE tracker dev, Open WebUI (chat history). Everything else (Prometheus TSDB, Loki, Alertmanager state, container images) regenerates from the GitOps sources.

Backups live in Cloudflare R2 bucket `k8sbkp/longhorn/` — `critical-backup` Longhorn RecurringJob runs daily at 03:00 CET, retains 30 snapshots. Target URL: `s3://k8sbkp@auto/longhorn/`, credential secret `longhorn-r2-credentials` in `longhorn-system`.

## 1. Full cluster rebuild with data restore (the `make all` path)

The `make all` chain is now:

```
prepare → k3s → post-install → metallb → tailscale → longhorn → backup → restore-volumes → monitoring → gitea → argocd
```

`make restore-volumes` runs playbook `12-restore-volumes.yml` which:

1. Waits for Longhorn manager pods to be Running and the default `BackupTarget` CR to have a URL (populated by `make backup`).
2. Polls `backupvolumes.longhorn.io` until CRs appear — Longhorn pulls them from R2 on its `pollInterval` (5 min). Up to 7 min wait.
3. For each entry in `restore_targets`, parses `status.labels.KubernetesStatus` to match on `namespace + pvcName`, then reads the latest `Backup.status.url`.
4. Creates `longhorn.io/Volume` CR `restored-<ns>-<pvc>` with `spec.fromBackup` set — Longhorn starts pulling blocks from R2 immediately.
5. Waits for the Volume to reach `status.state == "detached"` — this is the "restore done, ready to attach" signal. Timeout 15 min per volume.
6. Creates a static `PersistentVolume` backed by the restored Longhorn volume (CSI driver `driver.longhorn.io`, `volumeHandle` set to the Longhorn volume name), `reclaimPolicy: Retain`, and a `claimRef` pointing at the target PVC.
7. Creates the target namespace if missing.
8. Creates the `PersistentVolumeClaim` with matching namespace + name, `spec.volumeName` = the PV, `storageClassName: longhorn`. `claimRef` + `volumeName` make the binding deterministic.
9. Waits up to 10 min for each PVC to reach `status.phase == "Bound"`.

Helm installs of Grafana and Gitea now use `--take-ownership` so that when the rendered chart produces a PVC with the same name as the pre-created one, Helm adopts it into release state instead of erroring with "resource already exists".

**Restore list is parameterized in the playbook header** — edit `restore_targets:` to add/remove volumes:

```yaml
restore_targets:
  - { namespace: gitea,           pvc: gitea-shared-storage, size: 10Gi, access_mode: ReadWriteOnce, storage_class: longhorn }
  - { namespace: monitoring,      pvc: grafana,              size: 5Gi,  access_mode: ReadWriteOnce, storage_class: longhorn }
  - { namespace: eve-tracker,     pvc: eve-tracker-data,     size: 1Gi,  access_mode: ReadWriteOnce, storage_class: longhorn }
  - { namespace: eve-tracker-dev, pvc: eve-tracker-data,     size: 1Gi,  access_mode: ReadWriteOnce, storage_class: longhorn }
  - { namespace: open-webui,      pvc: open-webui-data,      size: 2Gi,  access_mode: ReadWriteOnce, storage_class: longhorn }
```

**Dry-run before you commit**:

```bash
make restore-volumes-dry-run
```

Runs the `preflight`, `discover`, and `resolve` tags only. Prints the full restore plan (target PVC → backup URL → source volume → bytes) without creating anything. Safe to run on a live cluster.

### Fresh install with no backups

If R2 is empty (first rebuild, retention wiped, etc.), `discover` finds no `BackupVolume` CRs matching the target list. The `restore` stage then falls back to creating empty PVCs with dynamic provisioning — the downstream Helm install still finds a PVC to mount, just starts with no data. No change needed to the chain.

### Gotcha: ArgoCD-managed PVCs hit immutable-field OutOfSync

Restored PVCs have `spec.volumeName` set (statically bound to the restored PV). If the PVC is managed by an ArgoCD Application that renders the PVC from a Kustomize source WITHOUT `volumeName` (normal for fresh installs), ArgoCD's 3-way merge will try to unset `volumeName` during sync and fail with:

```
PersistentVolumeClaim "X" is invalid: spec: Forbidden: spec is immutable after
creation except resources.requests and volumeAttributesClassName for bound claims
```

Hit this 2026-04-15 on `eve-tracker` + `eve-tracker-dev`. Two fixes required:

1. On the Application, add `ignoreDifferences` for `/spec/volumeName` and any labels the restore added (`/metadata/labels/longhorn-restore`), plus `syncOptions: [RespectIgnoreDifferences=true, ServerSideApply=true]`. This is already baked into `k8s/argocd/eve-tracker-app.yml` and `eve-tracker-dev-app.yml`.

2. After the initial `kubectl apply` of the restored PVC, strip the `kubectl.kubernetes.io/last-applied-configuration` annotation:
   ```bash
   for ns in eve-tracker eve-tracker-dev; do
     kubectl -n $ns annotate pvc eve-tracker-data \
       kubectl.kubernetes.io/last-applied-configuration-
   done
   ```
   Without this, ArgoCD's 3-way merge uses the restore playbook's kubectl-apply history (which baked in `volumeName`) as the "previous state", and the merge still tries to unset the field even with `RespectIgnoreDifferences`. Stripping the annotation drops 3-way merge to 2-way (source vs live), which correctly honors the field-manager ownership.

Follow-up: fold the annotation-strip step into `12-restore-volumes.yml` so this is automatic on the next rebuild.

## 2. Post-rebuild validation

After `make all` finishes:

```bash
# All restored PVs are Retained and bound
kubectl get pv -l longhorn-restore

# Each target PVC is Bound to its restored PV (not a fresh one)
for target in gitea/gitea-shared-storage monitoring/grafana \
              eve-tracker/eve-tracker-data eve-tracker-dev/eve-tracker-data \
              open-webui/open-webui-data; do
  kubectl get pvc -n ${target%/*} ${target#*/} \
    -o jsonpath='{.metadata.namespace}/{.metadata.name}  {.status.phase}  {.spec.volumeName}{"\n"}'
done

# Longhorn sees every volume as attached + healthy
kubectl -n longhorn-system get volumes.longhorn.io
```

Sanity-check the apps:

- **Gitea**: `make ssh-1`, `kubectl -n gitea exec -it deploy/gitea -- gitea admin user list` — users preserved? Web UI login with the admin account from `vault.yml` succeeds?
- **Grafana**: Browse to `grafana.<local_domain>`, verify dashboards (the Trivy panel, the Longhorn panel) and starred items are back.
- **EVE tracker**: Hit the production URL, check that existing character data loads (not just a fresh database).
- **Open WebUI**: `chat.<local_domain>` — login should show prior conversations.

## 3. Manual Longhorn UI restore (fallback if playbook fails)

Use this when `make restore-volumes` errors out mid-flight and you need to recover one PVC by hand.

1. Longhorn UI: `http://longhorn.<local_domain>` (LAN only — not exposed via Cloudflare).
2. **Backup** tab → pick the PVC's latest backup → click **Restore**.
3. Fill in:
   - Volume name: `restored-<ns>-<pvc>` (convention matching the playbook)
   - Number of replicas: 2
   - (Leave other fields at defaults)
4. Wait for the volume to finish restoring (Volumes tab → state `Detached`).
5. Create the PV + PVC manifests manually — use the templates from `12-restore-volumes.yml` as reference (search for `kind: PersistentVolume` and `kind: PersistentVolumeClaim` inside `<<EOF` heredocs).
6. `kubectl apply -f <your-manifest>`, then `kubectl get pvc -n <ns> <pvc>` to confirm binding.

## 4. Recover from a specific scenario

### Stuck volume (pod can't mount, state `Attaching` forever)

```bash
# Force-detach
kubectl -n longhorn-system patch volume <vol-name> \
  --type=merge -p '{"spec":{"nodeID":""}}'

# Wait for state=detached, then scale the pod back to trigger re-attach
kubectl -n <ns> rollout restart deployment <deploy>
```

Known trigger: node reboot while a pod held the volume. Longhorn sometimes leaves the engine thinking the old node still owns the attachment.

### Replica lost after node failure

When a node goes away (faulty CM5, Proxmox VM dies, disk full), Longhorn marks its replicas as `Failed` and the volume goes `Degraded`. Recovery is automatic as long as the replica count permits: Longhorn picks a healthy node with free capacity and rebuilds.

```bash
# See which volumes are degraded
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,REPLICAS:.spec.numberOfReplicas'

# Watch a specific volume rebuild
watch -n 5 "kubectl -n longhorn-system get replicas -l longhornvolume=<vol-name>"
```

Per the storage strategy in `feedback_longhorn_storage` memory: big volumes (Prometheus TSDB, Loki chunks) have their replicas pinned to x86 nodes (`k3s-x86-1`, `k3s-x86-2`) because 32GB Pi eMMC can't host them. If BOTH x86 nodes are down, those volumes go `Faulted` and can't auto-rebuild — restore from R2 is the only path.

### Expand a PVC online

Longhorn supports online resize. Edit the PVC's `spec.resources.requests.storage` to the new size; Longhorn grows the volume and, if the filesystem supports it (ext4 does, XFS does), grows the filesystem too.

```bash
kubectl -n <ns> patch pvc <pvc-name> \
  --type=merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

kubectl -n longhorn-system get volume <vol-name> \
  -o jsonpath='{.status.actualSize} {.spec.size}'
```

Caveat: shrinking is not supported — you'd need to back up, recreate smaller, restore.

### Replica rebuild after disk wipe

If you `nuke` a node and reinstall the OS without preserving `/var/lib/longhorn`, the node comes back with no replica data. Longhorn sees the replicas as permanently lost and rebuilds from the surviving replicas on other nodes. No manual action needed unless you only had one replica (e.g., Gitea during `make gitea` before first backup) — in which case, restore from R2.

## 5. Backup target + recurring job invariants

Don't forget these when touching the backup configuration — they are set by `11-configure-backups.yml` Play 2:

- **BackupTarget URL**: `s3://k8sbkp@auto/longhorn/`
- **Credential secret**: `longhorn-r2-credentials` in `longhorn-system`, keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS`
- **Poll interval**: 5 min — controls how fast the UI reflects new uploads
- **`critical-snapshot`** RecurringJob: cron `0 2 * * *`, group `critical`, retain 7 local snapshots
- **`critical-backup`** RecurringJob: cron `0 3 * * *`, group `critical`, retain 30 R2 backups
- Volumes in the `critical` group: all 5 from `restore_targets` above — adding a new stateful app means tagging its PVC's Longhorn volume with the `critical` group label (see `11-configure-backups.yml` for the pattern).

## 6. What this runbook does NOT cover

- **Prometheus TSDB / Loki / Alertmanager restore** — intentionally not backed up. Retention starts over after a rebuild. Accept the gap and move on.
- **Longhorn system namespace recovery** — if `longhorn-system` itself is corrupted beyond repair, `make nuke && make all` is the only path.
- **R2 bucket loss** — if the bucket is deleted, backups are gone. Only on-disk replicas survive (still on the nodes' `/var/lib/longhorn`, not touched by K3s uninstall). See scenario 4 "Replica rebuild after disk wipe" for the reverse case. There is no off-R2 offsite backup today — out of scope for now.
