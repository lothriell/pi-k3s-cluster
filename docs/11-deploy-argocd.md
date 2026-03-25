# 11 - Deploy ArgoCD: GitOps Continuous Delivery

## What you'll learn

- What ArgoCD is and the GitOps concept it is built on
- How ArgoCD and Gitea work together to automate deployments
- How to deploy ArgoCD to your cluster with a single command
- How to log in to the ArgoCD dashboard
- How to connect ArgoCD to your local Gitea instance
- How to create your first ArgoCD-managed application
- How to push code to Gitea and watch ArgoCD deploy it automatically

---

## What is ArgoCD?

ArgoCD is a **GitOps** tool for Kubernetes. The idea behind GitOps is simple:

> **You push code to Git. ArgoCD automatically deploys it to your cluster.**

That is the entire workflow. You never run `kubectl apply` manually again.
Instead, you put your Kubernetes YAML files in a Git repository (on your Gitea
instance), and ArgoCD watches that repository. When it detects a new commit, it
compares what is in Git with what is running on the cluster and automatically
applies the difference.

If someone manually changes something on the cluster (with `kubectl edit`, for
example), ArgoCD will notice the drift and revert it back to match Git. **Git
is the single source of truth.**

### Why this matters

Without ArgoCD, deploying to your cluster looks like this:

```
Edit YAML files -> run kubectl apply -> hope you applied the right files
```

With ArgoCD, it becomes:

```
Edit YAML files -> git push -> ArgoCD handles the rest
```

This gives you:

- **Audit trail** -- every change is a Git commit, so you know who changed
  what and when
- **Easy rollback** -- revert a Git commit and ArgoCD rolls back the deployment
- **Self-healing** -- if something drifts from the desired state, ArgoCD fixes
  it automatically

---

## How Gitea and ArgoCD work together

You already have Gitea running on your cluster from the previous guide. Here is
how the two services fit together:

```
┌─────────────┐         ┌──────────────┐         ┌──────────────┐
│             │  push   │              │  watch   │              │
│  You (Mac)  │────────►│    Gitea     │◄─────────│   ArgoCD     │
│             │         │  (Git repos) │         │  (deploys)   │
└─────────────┘         └──────────────┘         └──────┬───────┘
                                                        │
                                                        │ apply
                                                        ▼
                                                 ┌──────────────┐
                                                 │  Kubernetes   │
                                                 │   cluster     │
                                                 └──────────────┘
```

1. **You** push Kubernetes manifests to a Gitea repository.
2. **ArgoCD** polls the repository (every 3 minutes by default) and detects the
   new commit.
3. **ArgoCD** compares the manifests in Git with the live state on the cluster.
4. **ArgoCD** applies any differences, creating, updating, or deleting
   resources as needed.

---

## What gets deployed

When you run the ArgoCD deployment, the playbook creates these components in
the `argocd` namespace:

- **ArgoCD Server** -- the API and web UI (what you see in your browser)
- **ArgoCD Controller** -- watches Git repos and reconciles cluster state
- **ArgoCD Repo Server** -- clones repos and renders manifests (YAML, Helm,
  Kustomize)
- **Redis** -- internal cache for ArgoCD

All tuned with lightweight resource limits for your Raspberry Pi CM5 nodes.

---

## Step 1 -- Deploy ArgoCD

From the project root, run:

```bash
make argocd
```

This runs the Ansible playbook that:

1. Creates the `argocd` namespace.
2. Adds the Argo Helm repository.
3. Installs ArgoCD via Helm with values tuned for your CM5 cluster.
4. Waits for all pods to become ready.

The deployment takes 2-5 minutes on the first run while container images are
downloaded to your Pi nodes.

---

## Step 2 -- Verify the deployment

Check that all pods are running:

```bash
kubectl get pods -n argocd
```

You should see something like:

```
NAME                                               READY   STATUS    RESTARTS   AGE
argocd-server-xxxxxxxxxx-xxxxx                     1/1     Running   0          3m
argocd-repo-server-xxxxxxxxxx-xxxxx                1/1     Running   0          3m
argocd-application-controller-0                    1/1     Running   0          3m
argocd-applicationset-controller-xxxxxxxxx-xxxxx   1/1     Running   0          3m
argocd-redis-xxxxxxxxxx-xxxxx                      1/1     Running   0          3m
```

All pods should show **Running** with `1/1` in the READY column.

---

## Step 3 -- Get the admin password

ArgoCD generates a random admin password on first install and stores it in a
Kubernetes secret. Retrieve it with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode; echo
```

Save this password. The username is `admin`.

> **Tip:** The Ansible playbook prints this password at the end of the deploy,
> so you may have already seen it in the output.

---

## Step 4 -- Access the ArgoCD UI

Forward the ArgoCD server port to your Mac:

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80
```

Open your browser and go to:

```
http://localhost:8080
```

Log in with:

- **Username:** `admin`
- **Password:** the password from Step 3

### What just happened?

You now have a GitOps deployment tool running on your cluster. The ArgoCD
dashboard shows all your managed applications, their sync status, and health.
Right now it is empty because we have not connected any repositories yet.

> **Note:** If you set up a Cloudflare Tunnel previously, you can also add
> ArgoCD to it. Add a public hostname rule for `argocd.yourdomain.com` pointing
> to `http://argocd-server.argocd.svc.cluster.local:80` in your Cloudflare
> Tunnel configuration. Then you can access ArgoCD from anywhere without
> port-forwarding.

---

## Step 5 -- Connect ArgoCD to Gitea

ArgoCD needs to know about your Gitea instance so it can clone repositories.
We do this by creating a Kubernetes Secret with the connection details.

Edit the repo secret template:

```bash
nano k8s/argocd/gitea-repo-secret.yml
```

Replace the `CHANGEME` values:

- **username** -- your Gitea admin username
- **password** -- your Gitea password (or better, create an access token in
  Gitea under **Settings > Applications > Generate New Token**)

Then apply it:

```bash
kubectl apply -f k8s/argocd/gitea-repo-secret.yml
```

### How ArgoCD discovers repos

ArgoCD watches for Kubernetes Secrets labeled with
`argocd.argoproj.io/secret-type: repository`. When it finds one, it reads the
URL and credentials and uses them to access repos at that URL. You do not need
to configure anything in the ArgoCD UI -- just create the Secret and ArgoCD
picks it up automatically.

You can verify the connection in the ArgoCD UI under **Settings > Repositories**.
Your Gitea URL should appear there with a green checkmark.

---

## Step 6 -- Create a test repo in Gitea

Before we create an ArgoCD Application, we need something to deploy. Let's
create a simple nginx deployment in a Gitea repo.

First, make sure Gitea port-forward is running (in a separate terminal):

```bash
kubectl port-forward -n gitea svc/gitea-http 3030:3000
```

Create a new repository in Gitea called `nginx-demo` (via the web UI at
`http://localhost:3030` or using the API).

On your Mac, create the deployment manifests:

```bash
mkdir -p ~/nginx-demo && cd ~/nginx-demo
git init
```

Create a namespace file:

```bash
cat > namespace.yml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-demo
EOF
```

Create a simple nginx deployment:

```bash
cat > deployment.yml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: nginx-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
EOF
```

Push it to Gitea:

```bash
git add .
git commit -m "Initial nginx deployment"
git remote add gitea http://localhost:3030/admin/nginx-demo.git
git push -u gitea main
```

Replace `admin` with your Gitea username if it is different.

---

## Step 7 -- Create your first ArgoCD Application

Now we tell ArgoCD to watch that repo and deploy it. Edit the example
Application manifest:

```bash
nano k8s/argocd/example-app.yml
```

Update the `CHANGEME` values:

- **repoURL** -- set to
  `http://gitea-http.gitea.svc.cluster.local:3000/<your-username>/nginx-demo.git`
- **namespace** -- set to `nginx-demo`

Apply it:

```bash
kubectl apply -f k8s/argocd/example-app.yml
```

### What each field means

The Application manifest has three key sections:

- **source** -- where the manifests live (Git repo URL, branch, path within
  the repo)
- **destination** -- where to deploy (which cluster and namespace)
- **syncPolicy** -- how to handle changes:
  - `automated` -- sync without manual approval
  - `prune: true` -- delete resources removed from Git
  - `selfHeal: true` -- revert manual cluster changes to match Git

---

## Step 8 -- Watch ArgoCD deploy

Open the ArgoCD UI at `http://localhost:8080`. You should see your
`example-app` appear. Click on it to see:

- **Sync status** -- is the cluster in sync with Git?
- **Health status** -- are all the pods running and healthy?
- **Resource tree** -- a visual map of all Kubernetes resources created by
  this app (namespace, deployment, replica set, pods)

ArgoCD will sync within a few minutes (it polls every 3 minutes by default).
You can also click the **Sync** button to trigger an immediate sync.

Once synced, verify the deployment:

```bash
kubectl get pods -n nginx-demo
```

You should see two nginx pods running -- deployed entirely by ArgoCD, not by
you running `kubectl apply`.

---

## Step 9 -- Test the GitOps workflow

Now for the magic. Change the replica count in your nginx-demo repo and watch
ArgoCD react.

```bash
cd ~/nginx-demo
```

Edit `deployment.yml` and change `replicas: 2` to `replicas: 3`. Then push:

```bash
git add .
git commit -m "Scale nginx to 3 replicas"
git push
```

Within a few minutes, check the ArgoCD UI or run:

```bash
kubectl get pods -n nginx-demo
```

You should now see **three** nginx pods. ArgoCD detected the change in Git and
applied it automatically.

### Test self-healing

Try manually scaling the deployment:

```bash
kubectl scale deployment nginx -n nginx-demo --replicas=1
```

Watch what happens -- within a few minutes, ArgoCD will scale it back to 3
replicas because Git says there should be 3. Git always wins.

---

## ArgoCD UI tour

Here is a quick tour of the ArgoCD dashboard:

- **Applications view** -- the main page shows all your ArgoCD-managed apps
  as cards. Green means healthy and in sync.
- **App detail view** -- click an app to see the resource tree, sync status,
  and health of each resource.
- **Diff view** -- when an app is out of sync, click **App Diff** to see
  exactly what changed (like `git diff` but for your cluster).
- **History** -- see all past sync operations and which Git commits triggered
  them.
- **Settings > Repositories** -- verify your Gitea connection.
- **Settings > Clusters** -- see connected clusters (your local cluster
  appears as `in-cluster`).

---

## Troubleshooting

**ArgoCD pods stuck in `Pending` or `CrashLoopBackOff`:**

Check if the node has enough resources:

```bash
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-server
```

Look for events about insufficient CPU or memory.

**"Repository not accessible" in ArgoCD UI:**

Verify the repo secret is correct:

```bash
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository
```

Make sure the Gitea URL uses the in-cluster service name
(`gitea-http.gitea.svc.cluster.local`), not `localhost`.

**App stuck in "Unknown" or "OutOfSync":**

Click the app in the ArgoCD UI and check the **Events** tab. Common issues:
- Wrong path in the Application manifest
- Invalid YAML in the Git repo
- Target namespace does not exist (enable `CreateNamespace=true` in syncOptions)

**Cannot reach ArgoCD UI:**

Make sure the port-forward is running:

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80
```

---

## Checklist

Before moving on, confirm:

- [ ] `kubectl get pods -n argocd` shows all pods Running
- [ ] You can reach ArgoCD at `http://localhost:8080` (with port-forward)
- [ ] You logged in with the admin password
- [ ] ArgoCD is connected to Gitea (visible under Settings > Repositories)
- [ ] You deployed the nginx-demo app via ArgoCD
- [ ] You pushed a change to Gitea and ArgoCD deployed it automatically

---

## Next step

[12 - What to Build Next](12-what-to-build-next.md)
