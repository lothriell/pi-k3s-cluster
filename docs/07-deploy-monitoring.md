# 07 - Deploy Monitoring: Prometheus + Grafana

## What you'll learn

- Why monitoring matters for a home cluster
- What Prometheus and Grafana do and how they work together
- How Helm installs applications into Kubernetes
- How to deploy the full monitoring stack with a single command
- How to access Grafana and import dashboards

---

## Why monitoring matters

Without monitoring, you are flying blind. A Pi could be running out of memory,
a pod could be crash-looping, or your SSD could be filling up -- and you would
not know until something breaks.

Monitoring gives you two superpowers:

1. **Know when things break** -- you can see errors and restarts at a glance.
2. **See resource usage** -- CPU, memory, disk, and network for every node and
   every pod.

---

## What we are deploying

We are installing two tools that work together:

| Tool | What it does |
|------|-------------|
| **Prometheus** | Collects metrics from your cluster. It scrapes numbers (CPU usage, memory, pod count, etc.) from every node and pod on a schedule and stores them in a time-series database. |
| **Grafana** | Visualizes those metrics. It connects to Prometheus and turns the raw numbers into graphs, gauges, and dashboards you can view in a browser. |

```
┌──────────┐    scrapes metrics     ┌──────────────┐
│ Your Pis │  ◄──────────────────── │  Prometheus   │
│ (nodes)  │                        │  (collector)  │
└──────────┘                        └──────┬───────┘
                                           │ queries
                                    ┌──────▼───────┐
                                    │   Grafana     │
                                    │  (dashboards) │
                                    └──────────────┘
                                           │
                                     your browser
```

---

## How Helm works (quick primer)

You already installed Helm in [00-prerequisites.md](00-prerequisites.md). Here
is the mental model:

- **apt/brew** installs software on a single machine.
- **Helm** installs software into a Kubernetes cluster.

Helm packages are called **charts**. A chart is a bundle of Kubernetes YAML
files with sensible defaults. Instead of writing dozens of YAML files by hand,
you run one Helm command and it creates all the Deployments, Services,
ConfigMaps, and other resources for you.

Charts live in **repositories** (like brew taps). Before you can install a
chart, you add its repository.

---

## Step 1 -- Add the Helm repositories

These commands tell Helm where to find the charts we need:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### What just happened?

You registered two chart repositories with Helm:

- `prometheus-community` -- maintained by the Prometheus project, contains the
  Prometheus chart (and many others).
- `grafana` -- maintained by Grafana Labs, contains the Grafana chart.

`helm repo update` fetches the latest list of available charts from both repos,
like running `brew update`.

---

## Step 2 -- Deploy the monitoring stack

Run a single command from the project root:

```bash
make monitoring
```

This runs an Ansible playbook behind the scenes. You can watch the output as
each task completes.

### What the playbook does

1. **Creates the `monitoring` namespace** -- a dedicated area in your cluster
   for all monitoring resources, keeping them separate from your apps.

2. **Installs Prometheus via Helm** -- deploys the Prometheus server, node
   exporters (which run on every Pi to collect hardware metrics), and
   kube-state-metrics (which collects Kubernetes-level metrics like pod status).

3. **Installs Grafana via Helm** -- deploys the Grafana web server, configures
   it to use Prometheus as a data source automatically, and loads a default
   Kubernetes dashboard.

---

## Step 3 -- Verify the deployment

Check that all pods are running:

```bash
kubectl get pods -n monitoring
```

You should see output similar to this (the exact names will vary):

```
NAME                                                     READY   STATUS    RESTARTS   AGE
prometheus-server-5b7d7d4f8c-xxxxx                       2/2     Running   0          2m
prometheus-node-exporter-xxxxx                            1/1     Running   0          2m
prometheus-node-exporter-xxxxx                            1/1     Running   0          2m
prometheus-node-exporter-xxxxx                            1/1     Running   0          2m
prometheus-node-exporter-xxxxx                            1/1     Running   0          2m
prometheus-kube-state-metrics-xxxxx                       1/1     Running   0          2m
grafana-xxxxxxxxxx-xxxxx                                  1/1     Running   0          2m
```

Key things to check:

- Every pod shows **Running** in the STATUS column.
- The READY column shows the expected count (e.g., `1/1` or `2/2`).
- There is one `node-exporter` pod per Pi (so 4 total).

If a pod shows `CrashLoopBackOff` or `Pending`, wait a minute and check again.
The first startup can take a couple of minutes on the CM5 while images download.

---

## Step 4 -- Access Grafana

Grafana runs inside the cluster. To reach it from your Mac, forward the port:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Now open your browser and go to:

```
http://localhost:3000
```

### Get the admin password

Grafana generates a random admin password and stores it as a Kubernetes secret.
Retrieve it with:

```bash
kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

### What just happened?

That command did three things:

1. `kubectl get secret` -- fetched the secret named `grafana` from the
   `monitoring` namespace.
2. `-o jsonpath="{.data.admin-password}"` -- extracted just the password field.
3. `| base64 --decode` -- decoded it from base64 (Kubernetes stores all secret
   values base64-encoded).

Log in with:

- **Username:** `admin`
- **Password:** the output from the command above

---

## Step 5 -- Explore the default dashboard

After logging in, click the **hamburger menu** (three horizontal lines, top
left) and go to **Dashboards**. You should see a pre-loaded Kubernetes cluster
overview dashboard that shows:

- Node CPU and memory usage
- Pod counts and status
- Network traffic

Click into it and explore. The graphs update in near-real-time.

---

## Step 6 -- Import additional dashboards

The Grafana community publishes thousands of free dashboards at
[grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards). You
can import any of them by ID.

A great one for Kubernetes clusters:

| Dashboard | ID | What it shows |
|-----------|----|---------------|
| Kubernetes cluster monitoring | **15757** | CPU, memory, network per node and pod |

To import it:

1. In Grafana, click **Dashboards** in the left menu.
2. Click **New** (top right) then **Import**.
3. Type `15757` in the "Import via grafana.com" field and click **Load**.
4. In the "Prometheus" dropdown at the bottom, select your Prometheus data
   source.
5. Click **Import**.

You now have a detailed cluster dashboard. Repeat this process with any
dashboard ID you find on grafana.com.

---

## What about accessing Grafana without port-forward?

Right now you need to run `kubectl port-forward` every time you want to see
Grafana. That is fine for quick checks, but not ideal.

In [09-cloudflare-tunnel.md](09-cloudflare-tunnel.md) you will set up a
Cloudflare Tunnel so you can access Grafana at `grafana.yourdomain.com` from
anywhere -- no port-forwarding, no VPN, no opening ports on your router.

---

## Troubleshooting

**Pods stuck in `Pending`:**

```bash
kubectl describe pod <pod-name> -n monitoring
```

Look at the Events section at the bottom. Common causes: not enough memory or
CPU on the nodes, or no available storage.

**Grafana shows "No data" on dashboards:**

Make sure Prometheus is healthy:

```bash
kubectl logs -n monitoring deployment/prometheus-server --tail=20
```

If you see errors about scraping, give it a few more minutes. Prometheus needs
time to collect its first round of metrics.

---

## Checklist

Before moving on, confirm:

- [ ] `kubectl get pods -n monitoring` shows all pods Running
- [ ] You can reach Grafana at `http://localhost:3000` (with port-forward)
- [ ] You can log in with the admin password
- [ ] You see data on at least one dashboard

---

## Next step

[08 - Deploy Gitea: Your Self-Hosted Git Service](08-deploy-gitea.md)
