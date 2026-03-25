# 05 - Install K3s

## What you'll learn

- What K3s is and how it compares to "full" Kubernetes
- How the server/agent architecture works (the simple version)
- What the install playbook does step by step
- How to run the installer and verify your cluster is alive
- What kubeconfig is and why it matters
- What K3s bundles for free (networking, DNS, storage, ingress)
- How to troubleshoot nodes that won't join

---

## What is K3s?

Kubernetes (often shortened to **K8s** -- the "8" stands for the eight letters between K and s) is the industry-standard system for running containers across multiple machines. It handles deploying your apps, scaling them up, restarting them when they crash, and networking them together.

The problem: full Kubernetes is *complex*. It's made up of many separate components (etcd, kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy, kubelet...) that all need to be installed, configured, and maintained individually. It was built for massive data centers with dedicated operations teams.

**K3s** is Kubernetes distilled down to a **single binary**. Rancher Labs took full Kubernetes, stripped out cloud-provider-specific code and rarely used features, bundled the essential components together, and packaged it all into one ~70 MB file. It's fully certified Kubernetes -- any app that works on "real" Kubernetes works on K3s -- it's just dramatically simpler to install and run.

K3s is purpose-built for exactly what you're doing: running Kubernetes on small ARM machines like Raspberry Pis.

| | Full Kubernetes (K8s) | K3s |
|---|---|---|
| Install | Many components, complex setup | Single binary, one command |
| RAM usage | Needs several GB | Runs comfortably in 512 MB |
| Architecture | x86 data centers | ARM and x86, edge devices |
| Certification | CNCF certified | Also CNCF certified |
| Storage backend | Requires etcd cluster | Built-in SQLite (or etcd) |
| Best for | Large-scale production | Home labs, edge, IoT, dev |

---

## Architecture: server vs agent

Think of your cluster like a restaurant.

### The server (pi-k3s-1) -- the manager

The **server** node runs the **control plane**. This is the brain of your cluster. It:

- Keeps track of what should be running and where
- Decides which worker node should run each container
- Stores the entire state of the cluster (what's deployed, what's healthy, configurations)
- Responds to your `kubectl` commands

In the restaurant analogy, the server node is the **manager**. It takes the orders (your deployment requests), decides which cook handles what, and keeps the books.

You have **one** server node: `pi-k3s-1`.

### The agents (pi-k3s-2, pi-k3s-3, pi-k3s-4) -- the workers

The **agent** nodes (also called **workers**) do the actual work of running your containers. They:

- Receive instructions from the server: "run this container"
- Report back to the server: "the container is healthy" or "the container crashed"
- Handle the actual network traffic to and from your apps

In the restaurant analogy, the agents are the **cooks**. They get orders from the manager and actually prepare the food.

You have **three** agent nodes: `pi-k3s-2`, `pi-k3s-3`, `pi-k3s-4`.

### How they connect

When an agent starts up, it reaches out to the server and says "I'd like to join the cluster." It proves it's authorized by presenting a **token** -- a secret string that the server generated during its own installation. If the token matches, the agent is welcomed into the cluster.

```
                          +-----------+
                          | pi-k3s-1  |
                          |  (server) |
                          | port 6443 |
                          +-----+-----+
                                |
              +-----------------+-----------------+
              |                 |                 |
        +-----+-----+    +-----+-----+    +-----+-----+
        | pi-k3s-2  |    | pi-k3s-3  |    | pi-k3s-4  |
        |  (agent)  |    |  (agent)  |    |  (agent)  |
        +-----------+    +-----------+    +-----------+
```

All communication flows over port **6443** (the Kubernetes API port).

---

## What the playbook does, step by step

The install playbook runs in two phases.

### Phase 1: Install K3s on the server (pi-k3s-1)

1. **Downloads and installs K3s** using the official install script from `https://get.k3s.io`. This is a single command that downloads the K3s binary, sets up the systemd service, and starts it.

2. **Starts K3s in server mode.** This means it runs the control plane components (API server, scheduler, controller manager) plus a local agent (the server node can also run containers, though for your cluster the workers will handle most of the load).

3. **Retrieves the node token.** After the server starts, it generates a secret token and saves it to `/var/lib/rancher/k3s/server/node-token`. The playbook reads this token so it can pass it to the agent nodes.

4. **Fetches the kubeconfig file.** This is the credentials file you need on your local machine (your Mac) to talk to the cluster with `kubectl`. The playbook copies it from the server and puts it at `~/.kube/config` on your Mac.

### Phase 2: Install K3s on the agents (pi-k3s-2, pi-k3s-3, pi-k3s-4)

1. **Downloads and installs K3s** using the same official install script.

2. **Starts K3s in agent mode** with two critical pieces of information:
   - `K3S_URL` -- the address of the server: `https://pi-k3s-1:6443`
   - `K3S_TOKEN` -- the secret token retrieved from the server in Phase 1

3. Each agent contacts the server, presents the token, and **joins the cluster**. The server now knows about this new worker and can schedule containers on it.

---

## How to run it

```bash
make k3s
```

Or the full command:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/install-k3s.yml
```

This will take 2-5 minutes. You'll see the same Ansible output format you saw in the prepare step -- task names with `ok`/`changed` statuses, and a PLAY RECAP at the end.

**Wait about 30 seconds after the playbook finishes** before verifying. The agent nodes need a moment to fully register with the server.

---

## Verify your cluster

### Check that all nodes joined

```bash
kubectl get nodes
```

You should see all four nodes with a `Ready` status:

```
NAME        STATUS   ROLES                  AGE   VERSION
pi-k3s-1   Ready    control-plane,master   2m    v1.31.4+k3s1
pi-k3s-2   Ready    <none>                 90s   v1.31.4+k3s1
pi-k3s-3   Ready    <none>                 88s   v1.31.4+k3s1
pi-k3s-4   Ready    <none>                 85s   v1.31.4+k3s1
```

### What just happened?

You just talked to your Kubernetes cluster from your Mac. Let's break down the output:

| Column | Meaning |
|---|---|
| **NAME** | The hostname of each node (your Raspberry Pi CM5 modules) |
| **STATUS** | `Ready` means the node is healthy and can accept work. This is what you want. |
| **ROLES** | `control-plane,master` means this node runs the brain. `<none>` means it's a pure worker. |
| **AGE** | How long ago the node joined the cluster |
| **VERSION** | The K3s (Kubernetes) version running on that node |

If `kubectl get nodes` works and shows four Ready nodes, **congratulations -- you have a working Kubernetes cluster.**

---

## What is kubeconfig?

When you ran `kubectl get nodes`, how did `kubectl` know where your cluster is, or that you're allowed to talk to it? The answer is the **kubeconfig** file.

### What's in it

The kubeconfig file contains three things:

1. **Cluster info** -- the address of your K3s server (`https://pi-k3s-1:6443`) and its certificate (to verify you're talking to the right server)
2. **User credentials** -- a certificate and key that prove you're an authorized admin
3. **Context** -- which cluster + user combination to use by default

### Where it lives

```
~/.kube/config
```

That's `/Users/myuser/.kube/config` on your Mac.

### How it got there

The Ansible playbook did this automatically:

1. It read the kubeconfig file from the server node at `/etc/rancher/k3s/k3s.yaml`
2. It replaced `127.0.0.1` in that file with the actual hostname/IP of your server (`pi-k3s-1`) so your Mac can reach it over the network
3. It saved the modified file to `~/.kube/config` on your Mac

You can look at it if you're curious:

```bash
cat ~/.kube/config
```

You'll see YAML with `clusters`, `users`, and `contexts` sections. You generally never need to edit this by hand.

### Why it matters

Every `kubectl` command reads this file to know where to send requests. If this file is missing or wrong, `kubectl` will give you a connection error. If you ever see:

```
The connection to the server localhost:8080 was refused
```

...it means kubectl isn't finding a valid kubeconfig.

---

## What K3s installed for free

K3s doesn't just install Kubernetes -- it bundles several components that you'd otherwise have to install and configure yourself. Here's what's running in your cluster right now, even though you didn't deploy anything:

### Traefik (ingress controller)

**What it does:** Routes HTTP/HTTPS traffic from outside the cluster to the right service inside the cluster. When you eventually set up `myapp.home.lab` to point to your cluster, Traefik is the front door that reads the URL and sends the request to the right app.

**Namespace:** `kube-system`

### Flannel (container networking)

**What it does:** Creates a virtual network that spans all four nodes. This is what lets a container on pi-k3s-2 talk to a container on pi-k3s-4 as if they were on the same local network. Without Flannel, pods on different nodes would be isolated.

**Namespace:** `kube-system`

### CoreDNS (internal DNS)

**What it does:** Provides DNS inside the cluster. When one of your apps needs to talk to a database service, it can just use the name `my-database.my-namespace.svc.cluster.local` and CoreDNS resolves it to the right internal IP address. You don't have to hard-code IPs.

**Namespace:** `kube-system`

### local-path-provisioner (storage)

**What it does:** Automatically creates storage on the node's local disk when a container requests persistent storage. If your app says "I need 5 GB of disk," this provisioner carves out a directory on the node and hands it over. It's simple and perfect for a home lab.

**Namespace:** `kube-system`

### ServiceLB / Klipper (load balancer)

**What it does:** In cloud environments, you'd use the cloud provider's load balancer (like AWS ELB). You're not in a cloud, so K3s includes its own lightweight load balancer. When you create a Service of type `LoadBalancer`, ServiceLB handles it by opening the port on every node.

**Namespace:** `kube-system`

### See them all running

```bash
kubectl get pods -n kube-system
```

You'll see pods for all of the above. Don't worry about understanding every pod yet -- just know that K3s has set up a fully functional cluster with networking, DNS, storage, and ingress out of the box.

---

## Troubleshooting

### kubectl: connection refused

```
The connection to the server pi-k3s-1:6443 was refused
```

**Causes:**
- K3s server isn't running on pi-k3s-1
- Your kubeconfig isn't pointing to the right address

**Fix:**

1. Check if K3s is running on the server node:
   ```bash
   ssh pi-k3s-1
   sudo systemctl status k3s
   ```
   You should see `active (running)`. If it says `failed` or `inactive`, start it:
   ```bash
   sudo systemctl start k3s
   ```

2. Check your kubeconfig points to the right host:
   ```bash
   grep server ~/.kube/config
   ```
   It should show `https://pi-k3s-1:6443` (or the IP of pi-k3s-1).

### A node shows "NotReady"

```
NAME        STATUS     ROLES                  AGE   VERSION
pi-k3s-3   NotReady   <none>                 30s   v1.31.4+k3s1
```

**Fix:**

1. **Wait a minute.** Nodes sometimes need 30-60 seconds to fully initialize, especially right after installation. Run `kubectl get nodes` again after a minute.

2. If it's still NotReady, check the K3s agent service on that node:
   ```bash
   ssh pi-k3s-3
   sudo systemctl status k3s-agent
   ```

3. Check the logs for errors:
   ```bash
   ssh pi-k3s-3
   sudo journalctl -u k3s-agent -f --no-pager | tail -50
   ```
   Look for lines with `error` or `failed`.

### A node doesn't appear at all

If `kubectl get nodes` only shows 3 (or fewer) nodes, the missing node's agent never joined.

**Fix:**

1. **Check the K3s agent is running:**
   ```bash
   ssh pi-k3s-4   # whichever node is missing
   sudo systemctl status k3s-agent
   ```

2. **Check the token.** The agent needs the correct token to join. On the server:
   ```bash
   ssh pi-k3s-1
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```
   This should match what was used in the agent's configuration.

3. **Check the agent can reach the server on port 6443:**
   ```bash
   ssh pi-k3s-4
   curl -k https://pi-k3s-1:6443
   ```
   If this times out, there's a network or firewall issue between the nodes. Make sure port 6443 is open on pi-k3s-1.

4. **Restart the agent:**
   ```bash
   ssh pi-k3s-4
   sudo systemctl restart k3s-agent
   ```

### Playbook fails during install

If the Ansible playbook itself fails (red text, `failed=1` in PLAY RECAP):

1. Read the error message carefully -- Ansible usually tells you exactly what went wrong.

2. Common cause: the K3s install script couldn't download. Check the node has internet access:
   ```bash
   ssh pi-k3s-1
   curl -s https://get.k3s.io | head -5
   ```

3. Re-run the playbook. It's safe to run it again -- K3s's install script is idempotent:
   ```bash
   make k3s
   ```

---

## What's next?

Your cluster is running. Now you need to learn how to talk to it. The next guide covers `kubectl` -- the command-line tool you'll use every day -- plus K9s, a visual terminal UI that makes cluster management much more intuitive.

**Next step:** [06 - kubectl Basics](06-kubectl-basics.md)
