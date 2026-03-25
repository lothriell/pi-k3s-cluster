# 10 - Destroy and Rebuild: Testing Your Automation

## What you'll learn

- Why practicing destruction is valuable (not just scary)
- Exactly what `make nuke` does and does not destroy
- How to rebuild the entire cluster from scratch with a few commands
- How to verify everything came back correctly
- What data to back up before nuking

---

## Why practice destroying and rebuilding?

This might seem counterintuitive. You just spent hours setting everything up --
why would you tear it down?

Three important reasons:

1. **Confidence** -- If you know you can rebuild everything in 15 minutes, you
   stop being afraid of breaking things. Fear of breaking things is the biggest
   obstacle to learning.

2. **Disaster recovery** -- Hardware fails. SD cards corrupt. Pis overheat. If
   your only copy of the cluster exists as "stuff I configured by hand once,"
   you are one failure away from starting over from scratch with no guide. If
   your cluster is defined as code that you can re-run, you are one command
   away from being back.

3. **Proves your automation works** -- If you can nuke and rebuild, it means
   your Ansible playbooks, Helm charts, and Kubernetes manifests actually
   capture everything. No hidden manual steps, no "I SSH'd in and changed a
   config file that one time."

---

## What `make nuke` does

Run this from the project root:

```bash
make nuke
```

Here is what happens, step by step:

1. **Drains all workloads** -- tells Kubernetes to gracefully stop all pods on
   every node. Your applications get a chance to shut down cleanly.

2. **Uninstalls K3s from all agent nodes** -- runs the K3s uninstall script on
   pi-k3s-2, pi-k3s-3, and pi-k3s-4. This removes K3s, its containers, and
   its data directories.

3. **Uninstalls K3s from the server node** -- runs the K3s uninstall script on
   pi-k3s-1. The server node gets uninstalled last because agents need to
   deregister from it first.

4. **Cleans up local kubeconfig** -- removes the Kubernetes configuration file
   on your Mac so `kubectl` stops trying to connect to a cluster that no longer
   exists.

The whole process takes about **2 minutes**.

---

## What is NOT destroyed

This is just as important. `make nuke` only removes Kubernetes. Everything
else stays intact:

| Stays | Why |
|-------|-----|
| **Ubuntu OS** | You flashed this onto the SD cards. K3s uninstall does not touch the OS. |
| **Static IP addresses** | Configured at the OS level in netplan. Unchanged. |
| **SSH keys** | Your Mac's SSH key is in each Pi's `authorized_keys`. Unchanged. |
| **Hostnames** | Set at the OS level. Unchanged. |
| **Your Mac's tools** | Ansible, kubectl, Helm, etc. Still installed. |
| **This repository** | All your playbooks, manifests, and configs. Still on your Mac. |

In other words, the nuke takes you back to the state you were in right after
[03-ansible-common.md](03-ansible-common.md) (or wherever you had the OS
configured but no K3s installed).

---

## What IS lost

Be aware of what goes away:

| Lost | Why |
|------|-----|
| **All Kubernetes workloads** | Pods, Deployments, Services -- all gone. |
| **All Helm releases** | Prometheus, Grafana, Gitea -- uninstalled. |
| **Gitea repositories and data** | Stored on persistent volumes that get deleted with K3s. **Back up your repos first!** |
| **Grafana dashboards** (custom ones) | If you imported dashboards beyond the defaults, note their IDs. |
| **The Cloudflare tunnel K8s secret** | The tunnel still exists in Cloudflare, but you will need to re-create the Kubernetes secret. |

---

## Back up before you nuke

### Gitea repositories

If you have repos in Gitea you care about, clone them to your Mac first:

```bash
git clone https://gitea.yourdomain.com/youruser/your-repo.git
```

Or if using port-forward:

```bash
git clone http://localhost:3030/youruser/your-repo.git
```

### Grafana dashboard IDs

If you imported community dashboards, just write down the dashboard IDs (e.g.,
15757). You can re-import them after rebuilding.

### Cloudflare tunnel credentials

Make sure you still have the tunnel credentials JSON file on your Mac:

```bash
ls ~/.cloudflared/*.json
```

If that file exists, you are good. You will need it to re-create the Kubernetes
secret after rebuilding.

---

## The full rebuild process

### Step 1 -- Nuke the cluster

```bash
make nuke
```

Wait about 2 minutes for it to finish. You will see Ansible tasks running
against each node.

Verify the cluster is gone:

```bash
kubectl get nodes
```

This should fail with a connection error -- there is no cluster to connect to.

### Step 2 -- Rebuild everything

```bash
make all
```

This single command runs all the playbooks in order:

1. Common OS configuration (already done, but idempotent -- safe to re-run)
2. K3s server install on pi-k3s-1
3. K3s agent install on pi-k3s-2, pi-k3s-3, pi-k3s-4
4. MetalLB configuration
5. cert-manager installation
6. Monitoring stack (Prometheus + Grafana)
7. Gitea deployment

The rebuild takes about **10-15 minutes**. Most of that time is Helm
downloading container images to the Pis.

### Step 3 -- Re-create the Cloudflare tunnel secret

This is the one manual step. The tunnel still exists in Cloudflare, but the
Kubernetes secret was deleted with the cluster:

```bash
kubectl create namespace cloudflare

kubectl create secret generic cloudflare-tunnel-credentials \
  --namespace cloudflare \
  --from-file=credentials.json=/Users/yourname/.cloudflared/<TUNNEL-ID>.json
```

Then deploy cloudflared:

```bash
make cloudflare
```

---

## Verify the rebuild

Run through these checks to make sure everything came back:

### Nodes

```bash
kubectl get nodes
```

You should see all 4 nodes with status **Ready**:

```
NAME        STATUS   ROLES                  AGE   VERSION
pi-k3s-1   Ready    control-plane,master   5m    v1.31.x+k3s1
pi-k3s-2   Ready    <none>                 4m    v1.31.x+k3s1
pi-k3s-3   Ready    <none>                 4m    v1.31.x+k3s1
pi-k3s-4   Ready    <none>                 4m    v1.31.x+k3s1
```

### Monitoring

```bash
kubectl get pods -n monitoring
```

All pods should be Running. Port-forward Grafana and check you can log in:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Re-import any community dashboards you were using (e.g., ID 15757).

### Gitea

```bash
kubectl get pods -n gitea
```

All pods should be Running. Port-forward and go through the initial setup
again:

```bash
kubectl port-forward -n gitea svc/gitea-http 3030:3000
```

Create your admin account, then push your backed-up repos.

### Cloudflare Tunnel

```bash
kubectl get pods -n cloudflare
```

Visit `https://grafana.yourdomain.com` and `https://gitea.yourdomain.com` to
confirm external access works.

---

## Timing summary

| Action | Time |
|--------|------|
| `make nuke` | ~2 minutes |
| `make all` | ~10-15 minutes |
| Re-create Cloudflare secret + `make cloudflare` | ~2 minutes |
| **Total rebuild** | **~15-20 minutes** |

---

## Tips

- **Keep your Cloudflare tunnel credentials backed up.** If you lose the JSON
  file in `~/.cloudflared/`, you will need to delete the tunnel in Cloudflare
  and create a new one. Keep a copy somewhere safe (like a password manager).

- **Gitea data does not survive a nuke.** Always back up repositories to your
  Mac before destroying the cluster. You could also push important repos to
  GitHub as a secondary remote.

- **Run `make nuke && make all` periodically.** Doing this once a month keeps
  you confident that your automation still works. It only costs 20 minutes.

- **Future improvement: persistent storage with Longhorn.** Once you add M.2
  NVMe drives to your CM5 modules, you can set up Longhorn (a distributed
  storage system for Kubernetes). Longhorn replicates data across nodes, so
  even if one Pi dies, your data survives on the others. At that point, a nuke
  of a single node does not mean data loss.

---

## Checklist

- [ ] You ran `make nuke` and the cluster was removed
- [ ] You ran `make all` and the cluster was rebuilt
- [ ] All 4 nodes show Ready in `kubectl get nodes`
- [ ] Grafana is accessible and showing data
- [ ] Gitea is accessible and you re-created your admin account
- [ ] Cloudflare Tunnel is working (external URLs load)
- [ ] You feel confident you can rebuild from scratch

---

## What's next?

You have a fully automated, monitorable, self-hosted Kubernetes cluster that
you can destroy and rebuild at will. That is a serious accomplishment.

From here you can:

- **Deploy your own applications** -- write Kubernetes manifests or Helm charts
  for your projects.
- **Add M.2 NVMe storage** -- give your Pis fast, persistent storage and set
  up Longhorn.
- **Set up GitOps with Flux or ArgoCD** -- automatically deploy changes when
  you push to Gitea.
- **Explore Cloudflare Access** -- add authentication in front of your public
  services.
- **Try GitLab** -- with M.2 drives and more storage, you can run the full
  GitLab if you want.

Go back to the [README](../README.md) for the full project overview and links
to all guides.
