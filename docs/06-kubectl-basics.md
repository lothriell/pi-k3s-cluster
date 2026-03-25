# 06 - kubectl Basics

## What you'll learn

- What kubectl is and how it communicates with your cluster
- The core Kubernetes concepts you need to understand (pods, deployments, services, and more)
- The essential commands you'll use every day, with real examples and explained output
- How to use K9s, the visual terminal UI that makes everything easier
- The "I just deployed something, now what?" workflow

---

## What is kubectl?

**kubectl** (pronounced "cube-control" or "cube-C-T-L" -- people argue about this, either is fine) is the command-line tool for talking to your Kubernetes cluster.

Every time you want to ask your cluster a question ("what's running?") or tell it to do something ("deploy this app"), you use kubectl. It reads your kubeconfig file (`~/.kube/config`), connects to the K3s server on rpi-k3s-1, and sends your request.

Think of it like this:
- **You** type a kubectl command on your Mac
- **kubectl** sends that request over the network to rpi-k3s-1 on port 6443
- **The K3s server** processes the request and sends back a response
- **kubectl** formats the response and displays it in your terminal

---

## Essential concepts

Before diving into commands, you need to understand the building blocks. These are the core "things" that exist in a Kubernetes cluster.

### Pod

A **pod** is the smallest thing Kubernetes can run. It's one or more containers running together on the same node, sharing the same network and storage.

Most of the time, a pod is just one container. Think of a pod as a thin wrapper around your Docker container. Instead of running `docker run my-app`, Kubernetes creates a pod that runs your `my-app` container.

Why the wrapper? Because Kubernetes doesn't manage containers directly -- it manages pods. The pod provides a consistent abstraction that works regardless of the container runtime underneath.

**Key point:** You rarely create pods directly. You create a Deployment (see below), and it creates pods for you.

### Deployment

A **deployment** is how you tell Kubernetes "I want 3 copies of my app running at all times."

The Deployment watches over its pods. If one crashes, the Deployment notices and creates a replacement. If you say "actually, I want 5 copies," the Deployment spins up 2 more. If you push a new version of your app, the Deployment does a rolling update -- replacing pods one at a time so there's no downtime.

Think of a Deployment as a manager who makes sure the right number of workers are always on duty.

### Service

A **service** gives your pods a stable network address.

Here's the problem: pods are ephemeral. They get created and destroyed constantly. Each pod gets a random IP address, and that IP changes every time the pod restarts. How is anything supposed to connect to your app?

A Service solves this. It gets a fixed internal IP and DNS name (like `my-app.my-namespace.svc.cluster.local`) and routes traffic to whatever pods are currently healthy. Other apps in the cluster connect to the Service, not to individual pods.

Think of it like a phone number for a department. People call the department number, and whoever is working that day answers.

### Namespace

A **namespace** is like a folder to organize your stuff. It keeps resources separated and tidy.

Your cluster already has some namespaces:
- `kube-system` -- where K3s puts its own components (Traefik, CoreDNS, etc.)
- `default` -- where your stuff goes if you don't specify a namespace
- `kube-public` -- cluster-wide public resources (rarely used directly)
- `kube-node-lease` -- used by nodes to report heartbeats (you'll never touch this)

When you start deploying your own apps, you'll create namespaces like `monitoring`, `media`, `homelab`, etc. to keep things organized.

### Node

A **node** is a physical machine in your cluster. You have four nodes: your Raspberry Pi CM5 modules. rpi-k3s-1 is the server node (runs the control plane), and rpi-k3s-2/3/4 are agent nodes (run your workloads).

You already know this one from running `kubectl get nodes`.

### Ingress

An **ingress** routes external HTTP and HTTPS traffic to Services inside the cluster.

Say you have two apps: a blog and a dashboard. Both live inside the cluster. You want `blog.home.lab` to go to the blog and `dashboard.home.lab` to go to the dashboard. An Ingress resource defines those rules. Traefik (the ingress controller K3s installed) reads the Ingress rules and does the actual routing.

Without Ingress, you'd have to expose each app on a different port number (like `:8080`, `:8081`). With Ingress, everything comes in on port 80/443 and gets routed by hostname or URL path.

### PersistentVolume

A **PersistentVolume** (PV) is disk storage that survives pod restarts.

By default, when a pod dies, everything inside it is gone -- containers are ephemeral. But your database needs to keep its data. A PersistentVolume is a piece of storage (a directory on a node's disk, in your case) that gets mounted into a pod. When the pod restarts, the data is still there.

You request storage by creating a **PersistentVolumeClaim** (PVC) -- "I need 10 GB of storage." The local-path-provisioner that K3s installed automatically creates a PersistentVolume to satisfy that claim.

### Helm

**Helm** is the package manager for Kubernetes. It's like `apt` on Ubuntu or `brew` on your Mac, but for cluster applications.

Instead of writing dozens of YAML files to deploy something like Prometheus (a monitoring tool), you run:

```bash
helm install prometheus prometheus-community/prometheus
```

Helm downloads a **chart** (a package of pre-written YAML files), fills in your configuration values, and deploys everything to your cluster. When the app gets an update, `helm upgrade` handles it.

Most of the apps you'll deploy on your cluster will be installed through Helm charts.

---

## Must-know commands

These are the commands you'll use almost every time you interact with your cluster.

### See your nodes

```bash
kubectl get nodes
```

```
NAME        STATUS   ROLES                  AGE   VERSION
rpi-k3s-1   Ready    control-plane,master   1d    v1.31.4+k3s1
rpi-k3s-2   Ready    <none>                 1d    v1.31.4+k3s1
rpi-k3s-3   Ready    <none>                 1d    v1.31.4+k3s1
rpi-k3s-4   Ready    <none>                 1d    v1.31.4+k3s1
```

**What just happened?** You asked the cluster "show me all nodes." All four are `Ready`, meaning they're healthy and accepting work. If any showed `NotReady`, that node has a problem (see the troubleshooting section in [05-install-k3s.md](05-install-k3s.md)).

### See all pods across the entire cluster

```bash
kubectl get pods -A
```

The `-A` flag means "all namespaces." Without it, you'd only see pods in the `default` namespace (which is probably empty right now).

```
NAMESPACE     NAME                                      READY   STATUS    RESTARTS   AGE
kube-system   coredns-ccb96694c-xvg4k                   1/1     Running   0          1d
kube-system   helm-install-traefik-crd-hx4rm            0/1     Completed 0          1d
kube-system   helm-install-traefik-7k9gb                0/1     Completed 0          1d
kube-system   local-path-provisioner-5d56847996-mr9xk   1/1     Running   0          1d
kube-system   svclb-traefik-abcde-r4k2p                 2/2     Running   0          1d
kube-system   traefik-6b84cfd647-2m9kp                  1/1     Running   0          1d
```

**What just happened?** Let's break down the columns:

| Column | Meaning |
|---|---|
| **NAMESPACE** | Which namespace this pod lives in |
| **NAME** | The pod's name (auto-generated from the deployment name + random suffix) |
| **READY** | `1/1` means 1 out of 1 containers in the pod are ready. `2/2` means 2 of 2. All containers should be ready. |
| **STATUS** | `Running` = healthy and running. `Completed` = it ran, finished its job, and exited (normal for install jobs). |
| **RESTARTS** | How many times the pod has restarted. 0 is ideal. A high number means something keeps crashing. |
| **AGE** | How long the pod has been running |

The `Completed` pods are one-time install jobs (they installed Traefik's Helm chart). They're done and won't run again. This is normal.

### See all services

```bash
kubectl get services -A
```

```
NAMESPACE     NAME             TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                      AGE
default       kubernetes       ClusterIP      10.43.0.1       <none>          443/TCP                      1d
kube-system   kube-dns         ClusterIP      10.43.0.10      <none>          53/UDP,53/TCP,9153/TCP       1d
kube-system   traefik          LoadBalancer   10.43.171.142   10.0.0.100   80:31080/TCP,443:31443/TCP   1d
```

**What just happened?** Services are the stable network endpoints for your apps.

| Column | Meaning |
|---|---|
| **TYPE** | `ClusterIP` = only reachable inside the cluster. `LoadBalancer` = reachable from your home network. |
| **CLUSTER-IP** | The internal IP (only works inside the cluster). These are virtual and auto-assigned. |
| **EXTERNAL-IP** | The IP for accessing from outside the cluster. `<none>` means it's internal-only. |
| **PORT(S)** | The ports the service listens on |

The `traefik` service has an EXTERNAL-IP, which means you can point your browser to that IP and reach Traefik.

### See all namespaces

```bash
kubectl get namespaces
```

```
NAME              STATUS   AGE
default           Active   1d
kube-system       Active   1d
kube-public       Active   1d
kube-node-lease   Active   1d
```

This is a quick way to see what namespaces exist. As you deploy apps, you'll see more here.

### Get detailed info about a specific pod

```bash
kubectl describe pod coredns-ccb96694c-xvg4k -n kube-system
```

Replace the pod name with an actual pod name from `kubectl get pods -A`.

This dumps *everything* about that pod: what node it's running on, its IP, resource limits, environment variables, mounted volumes, and -- most importantly -- the **Events** section at the bottom.

**When to use this:** When a pod isn't starting or is in a crash loop. The Events section at the bottom tells you exactly what went wrong ("image not found," "insufficient memory," "volume mount failed," etc.).

```
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  1d    default-scheduler  Successfully assigned kube-system/coredns...
  Normal   Pulled     1d    kubelet            Container image already present on machine
  Normal   Created    1d    kubelet            Created container coredns
  Normal   Started    1d    kubelet            Started container coredns
```

### Read a pod's logs

```bash
kubectl logs coredns-ccb96694c-xvg4k -n kube-system
```

This shows what the container inside the pod has printed to stdout/stderr -- the same output you'd see with `docker logs`. If your app is crashing, the logs usually tell you why.

Useful flags:

```bash
# Follow logs in real-time (like tail -f)
kubectl logs -f coredns-ccb96694c-xvg4k -n kube-system

# Show last 50 lines only
kubectl logs --tail=50 coredns-ccb96694c-xvg4k -n kube-system

# Show logs from a crashed/previous pod instance
kubectl logs --previous coredns-ccb96694c-xvg4k -n kube-system
```

Press `Ctrl+C` to stop following logs.

### Deploy something from a YAML file

```bash
kubectl apply -f my-app.yml
```

This is how you create or update resources. The `-f` flag points to a YAML file that describes what you want. Kubernetes reads it and makes it happen.

`apply` is smart: if the resource doesn't exist, it creates it. If it already exists, it updates it to match the file. You can run it over and over safely.

**What just happened?** Kubernetes read the YAML file, compared it to what's currently running, and made any necessary changes.

### Delete something you deployed

```bash
kubectl delete -f my-app.yml
```

This removes everything that was defined in that YAML file. Pods, Services, Deployments -- all gone.

**Warning:** This is immediate and there's no "undo." The resources are deleted. (Your YAML file still exists on disk, so you can always `apply` it again.)

### Check resource usage

```bash
kubectl top nodes
```

```
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
rpi-k3s-1   245m         6%     1284Mi          8%
rpi-k3s-2   112m         2%     842Mi           5%
rpi-k3s-3   98m          2%     756Mi           4%
rpi-k3s-4   104m         2%     798Mi           5%
```

**What just happened?** This shows CPU and memory usage for each node. CPU is measured in "millicores" (m) -- 1000m = one full CPU core. Your CM5s have 4 cores each, so 4000m total per node. Memory is in mebibytes (Mi).

```bash
kubectl top pods -A
```

Same thing, but for individual pods. Useful to find which app is hogging resources.

> **Note:** `kubectl top` requires the metrics-server to be running. K3s includes it, but if these commands return an error, the metrics-server may need a minute to start collecting data after a fresh install.

---

## K9s: the visual terminal UI

`kubectl` is powerful, but typing commands to check on things gets tedious. **K9s** is a terminal-based UI that gives you a live, visual dashboard of everything in your cluster.

### Launch it

```bash
k9s
```

That's it. Your terminal transforms into a full-screen cluster dashboard.

### What you'll see

K9s opens to a pod view by default, showing all pods across all namespaces in a live-updating table. It refreshes automatically -- no need to re-run commands.

### Navigation

| Key | What it does |
|---|---|
| Arrow keys (up/down) | Move between items in the list |
| Enter | Drill into the selected item (e.g., show pod details) |
| Escape | Go back / close the current view |
| `:pods` | Switch to Pods view |
| `:services` or `:svc` | Switch to Services view |
| `:nodes` | Switch to Nodes view |
| `:deployments` or `:dp` | Switch to Deployments view |
| `:namespaces` or `:ns` | Switch to Namespaces view |
| `:helm` | Show Helm releases |
| `/` then type | Filter/search the current list (e.g., `/traefik` to find Traefik pods) |
| `d` | Describe the selected resource (same as `kubectl describe`) |
| `l` | View logs for the selected pod (same as `kubectl logs`) |
| `y` | Show the YAML definition of the selected resource |
| `Ctrl+d` | Delete the selected resource (asks for confirmation) |
| `0` | Show all namespaces |
| `Ctrl+c` | Quit K9s |

### Example workflow in K9s

1. Launch: `k9s`
2. You see all pods. Type `/traefik` to filter to Traefik pods.
3. Arrow down to the Traefik pod, press `l` to see its logs.
4. Press Escape to go back to the pod list.
5. Type `:nodes` then Enter to see your nodes and their resource usage.
6. Press Escape, type `:svc` to see all services.
7. Press `Ctrl+c` to quit.

### Why K9s is great for beginners

- **You don't need to memorize commands.** Everything is right there on screen, with keyboard shortcuts listed at the top.
- **It's real-time.** You can watch pods start up, become ready, or crash -- as it happens.
- **It's faster than kubectl for exploring.** Instead of running five different `kubectl get` commands, you're just pressing a few keys.
- **It shows you what exists.** When you're new, you don't even know what to ask for. K9s shows you everything, and you can browse around to learn what's running and how it fits together.

Start by just launching K9s and exploring. Switch between views with the colon commands, drill into things with Enter, and read the descriptions. You'll learn faster by looking at real resources than by reading documentation.

---

## Common workflow: "I deployed something, now what?"

You'll follow this pattern constantly. Here's the step-by-step checklist for after you deploy any app.

### Step 1: Apply the YAML or Helm chart

```bash
kubectl apply -f my-app.yml
# or
helm install my-app some-repo/some-chart -n my-namespace
```

### Step 2: Check that pods are running

```bash
kubectl get pods -n my-namespace
```

Wait for **STATUS** to show `Running` and **READY** to show `1/1` (or however many containers the pod has). This might take 30-60 seconds as the container image is downloaded to the node.

You'll often see these intermediate states:

| Status | Meaning | Action |
|---|---|---|
| `Pending` | Waiting to be scheduled to a node | Wait. If it stays Pending, run `kubectl describe pod <name> -n <namespace>` to see why. |
| `ContainerCreating` | The image is being pulled and the container is being set up | Wait. |
| `Running` | The app is up | Great, move to Step 3. |
| `CrashLoopBackOff` | The container starts and immediately crashes, over and over | Check logs: `kubectl logs <pod> -n <namespace>` |
| `ImagePullBackOff` | Kubernetes can't download the container image | Check the image name for typos. Check the node has internet access. |
| `Error` | The container exited with an error | Check logs: `kubectl logs <pod> -n <namespace>` |

### Step 3: Check the service

```bash
kubectl get services -n my-namespace
```

Make sure the Service exists and has the right type (`ClusterIP`, `LoadBalancer`, etc.). If it's a `LoadBalancer`, note the EXTERNAL-IP.

### Step 4: Check the ingress (if applicable)

```bash
kubectl get ingress -n my-namespace
```

Verify the hostname and that it's pointing to the right service.

### Step 5: Test access

- **If LoadBalancer:** Open `http://<EXTERNAL-IP>` in your browser.
- **If Ingress:** Open `http://your-hostname.home.lab` in your browser (assuming you've set up DNS to point that hostname to your cluster).
- **If ClusterIP only:** You can port-forward to test from your Mac:
  ```bash
  kubectl port-forward svc/my-service 8080:80 -n my-namespace
  ```
  Then open `http://localhost:8080` in your browser. Press `Ctrl+C` to stop port-forwarding.

### Step 6: If something is wrong

Follow this diagnostic order:

1. **Check pod status:** `kubectl get pods -n my-namespace`
2. **Describe the pod:** `kubectl describe pod <pod-name> -n my-namespace` (look at Events at the bottom)
3. **Read the logs:** `kubectl logs <pod-name> -n my-namespace`
4. **Check the service:** `kubectl get svc -n my-namespace` (is the port right? is the selector matching the pod labels?)
5. **Check the ingress:** `kubectl get ingress -n my-namespace` (is the hostname right? is the service name right?)

Or just launch K9s, find your pod, press `d` to describe it and `l` to see logs. Much faster.

---

## Quick reference cheat sheet

```bash
# Nodes
kubectl get nodes                        # List all nodes

# Pods
kubectl get pods -A                      # All pods, all namespaces
kubectl get pods -n <namespace>          # Pods in a specific namespace
kubectl describe pod <name> -n <ns>      # Detailed info about a pod
kubectl logs <name> -n <ns>              # Container logs
kubectl logs -f <name> -n <ns>           # Follow logs live

# Deployments
kubectl get deployments -n <ns>          # List deployments
kubectl scale deployment <name> -n <ns> --replicas=3   # Scale up/down

# Services
kubectl get services -A                  # All services
kubectl port-forward svc/<name> 8080:80 -n <ns>        # Access locally

# Namespaces
kubectl get namespaces                   # List namespaces

# Resources
kubectl top nodes                        # Node CPU/memory usage
kubectl top pods -A                      # Pod CPU/memory usage

# Apply / Delete
kubectl apply -f <file.yml>              # Create or update resources
kubectl delete -f <file.yml>             # Delete resources

# Visual UI
k9s                                      # Launch K9s dashboard
```

---

## What's next?

You now know how to talk to your cluster, understand the core concepts, and have the tools to deploy and debug applications. The next step is to start deploying actual workloads.

**Next step:** [07 - Deploying Your First App](07-deploying-first-app.md)
