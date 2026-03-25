# 08 - Deploy Gitea: Your Self-Hosted Git Service

## What you'll learn

- What Gitea is and why it is a great fit for a Raspberry Pi cluster
- How to deploy Gitea and its PostgreSQL database with a single command
- How to complete the initial setup and create your first admin account
- How to create a repository and push code to it
- How Gitea Actions can run CI/CD pipelines

---

## What is Gitea?

Gitea is a lightweight, self-hosted Git service. Think of it as your own
private GitHub running on your cluster. It gives you:

- **Git repositories** -- push and pull code just like GitHub
- **Issues and pull requests** -- track bugs, review code
- **CI/CD via Gitea Actions** -- run tests and builds automatically (similar
  syntax to GitHub Actions)
- **A web UI** -- browse code, manage users, configure settings

All of this runs on about **200 MB of RAM**, which is important when each of
your CM5 modules has limited resources.

---

## Why Gitea over GitLab?

You might wonder about GitLab, which is the other popular self-hosted Git
platform. Here is the comparison for a Raspberry Pi cluster:

| | Gitea | GitLab |
|---|-------|--------|
| **RAM usage** | ~200 MB | 4-8 GB |
| **CPU usage** | Minimal | Heavy |
| **Startup time** | Seconds | Several minutes |
| **Features** | Core Git + Issues + Actions | Everything imaginable |
| **ARM support** | Excellent | Works but resource-hungry |

For a 4-node CM5 cluster, Gitea is the right choice. It gives you everything
you need without starving your other workloads of resources.

> **Note:** If you want to experiment with GitLab later (especially once you
> add M.2 drives and have more storage), there are GitLab Helm values in the
> repo under `k8s/gitlab/`. It works, it just needs more resources than a
> minimal CM5 setup provides comfortably.

---

## What gets deployed

When you run the Gitea deployment, the playbook creates:

1. **Gitea server** -- the main application (web UI + Git SSH server)
2. **PostgreSQL database** -- stores user accounts, issues, pull requests, and
   other metadata (your actual Git repositories are stored on disk)
3. **Persistent storage** -- Kubernetes PersistentVolumeClaims that keep your
   data safe across pod restarts

```
┌─────────────────────────────────┐
│        gitea namespace          │
│                                 │
│  ┌──────────┐   ┌────────────┐ │
│  │  Gitea   │──►│ PostgreSQL │ │
│  │  server  │   │  database  │ │
│  └──────────┘   └────────────┘ │
│       │               │        │
│  ┌────▼────┐    ┌─────▼─────┐  │
│  │   PVC   │    │    PVC    │  │
│  │ (repos) │    │  (data)   │  │
│  └─────────┘    └───────────┘  │
└─────────────────────────────────┘
```

---

## Step 1 -- Deploy Gitea

From the project root, run:

```bash
make gitea
```

This runs the Ansible playbook that:

1. Creates the `gitea` namespace.
2. Adds the Gitea Helm repository.
3. Installs Gitea via Helm with values tuned for your CM5 cluster (resource
   limits, PostgreSQL configuration, storage settings).

The deployment takes 2-3 minutes. Helm will download the container images to
your Pis on the first run, which may take longer depending on your internet
speed.

---

## Step 2 -- Verify the deployment

Check that all pods are running:

```bash
kubectl get pods -n gitea
```

You should see something like:

```
NAME                     READY   STATUS    RESTARTS   AGE
gitea-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
gitea-postgresql-0       1/1     Running   0          2m
```

Both pods should show **Running** with `1/1` in the READY column. If the Gitea
pod shows `Init:0/1` or `CrashLoopBackOff`, wait a minute -- it might be
waiting for PostgreSQL to finish starting.

---

## Step 3 -- Access Gitea

Forward the Gitea service port to your Mac:

```bash
kubectl port-forward -n gitea svc/gitea-http 3030:3000
```

Open your browser and go to:

```
http://localhost:3030
```

> We use port 3030 here to avoid conflicting with Grafana on port 3000. You can
> use any free port you like.

---

## Step 4 -- Create your admin account

The first time you visit Gitea, you will see either the login page or a setup
wizard. If you see the setup wizard:

1. The database settings should already be configured (PostgreSQL). Do not
   change them.
2. Scroll down to **Administrator Account Settings**.
3. Fill in:
   - **Administrator Username:** pick something (e.g., `admin`)
   - **Password:** choose a strong password
   - **Email:** your email address
4. Click **Install Gitea**.

If the Helm chart pre-configured an admin account, the credentials will be in a
Kubernetes secret:

```bash
kubectl get secret -n gitea gitea-admin-secret -o jsonpath="{.data.username}" | base64 --decode; echo
kubectl get secret -n gitea gitea-admin-secret -o jsonpath="{.data.password}" | base64 --decode; echo
```

---

## Step 5 -- Create your first repository

Now let's take Gitea for a spin:

1. Click the **+** button in the top right and select **New Repository**.
2. Give it a name, like `hello-world`.
3. Check **Initialize this repository** (adds a README).
4. Click **Create Repository**.

You now have a Git repository hosted on your own cluster.

### Push code to it

On your Mac, create a test project and push it:

```bash
mkdir ~/hello-world && cd ~/hello-world
git init
echo "# Hello from my Pi cluster" > README.md
git add .
git commit -m "Initial commit"
```

Add your Gitea instance as a remote and push. While port-forwarding is active:

```bash
git remote add gitea http://localhost:3030/admin/hello-world.git
git push -u gitea main
```

Replace `admin` with your Gitea username if you chose something different.

### What just happened?

You pushed code from your Mac to a Git server running on your Raspberry Pi
cluster. The repository, its history, and all its files are stored on your
cluster's storage -- not on GitHub's servers, not on anyone else's
infrastructure. It is entirely yours.

---

## Step 6 -- Explore the UI

Take a few minutes to click around. Things worth exploring:

- **Settings** (gear icon on your repo) -- branch protection, webhooks,
  collaborators
- **Issues** -- create a test issue to see the tracker
- **Site Administration** (top right menu if you are admin) -- user management,
  system status, configuration

---

## Optional: Gitea Actions (CI/CD)

Gitea Actions lets you run automated workflows when you push code, similar to
GitHub Actions. It uses a compatible workflow syntax, so many GitHub Actions
workflows work with minimal changes.

Setting up a runner (the component that executes your workflows) is beyond the
scope of this guide, but here is the high-level process:

1. Enable Actions in Gitea's admin panel under **Site Administration > Settings**.
2. Deploy a Gitea runner in your cluster (it runs as a pod).
3. Create a `.gitea/workflows/ci.yaml` file in your repository.

For full details, see the official Gitea Actions documentation:
[docs.gitea.com/usage/actions/overview](https://docs.gitea.com/usage/actions/overview)

---

## What about accessing Gitea from outside?

Just like Grafana, you are currently using `kubectl port-forward` which only
works from your Mac while the command is running.

In [09-cloudflare-tunnel.md](09-cloudflare-tunnel.md) you will set up a
Cloudflare Tunnel so you can access Gitea at `gitea.yourdomain.com` from
anywhere. You will be able to clone repos, push code, and browse the UI from
any device.

---

## Troubleshooting

**Gitea pod stuck in `Init` or `CrashLoopBackOff`:**

Check the PostgreSQL pod first:

```bash
kubectl logs -n gitea gitea-postgresql-0 --tail=20
```

Gitea cannot start until PostgreSQL is healthy. If PostgreSQL is having trouble,
the issue is usually storage-related. Check:

```bash
kubectl describe pod gitea-postgresql-0 -n gitea
```

**"Repository not found" when pushing:**

Make sure the remote URL matches your username and repository name exactly. You
can check with:

```bash
git remote -v
```

**Port-forward disconnects frequently:**

This is normal. Kubernetes port-forwards are not designed for long-running
connections. The Cloudflare Tunnel setup in the next guide solves this
permanently.

---

## Checklist

Before moving on, confirm:

- [ ] `kubectl get pods -n gitea` shows all pods Running
- [ ] You can reach Gitea at `http://localhost:3030` (with port-forward)
- [ ] You created an admin account and can log in
- [ ] You created a test repository
- [ ] You pushed code to Gitea from your Mac

---

## Next step

[09 - Cloudflare Tunnel: Access Your Services From Anywhere](09-cloudflare-tunnel.md)
