# 09 - Cloudflare Tunnel: Access Your Services From Anywhere

## What you'll learn

- The problem with accessing home-hosted services from outside your network
- How Cloudflare Tunnel solves this without opening ports on your router
- How to set up a Cloudflare account and add your domain
- How to create a tunnel and deploy it in your cluster
- How to access Grafana and Gitea at real domain names with HTTPS

---

## The problem

Right now your Grafana and Gitea are only accessible from your home network
using `kubectl port-forward`. That is not ideal for several reasons:

- You cannot access your services from your phone, from work, or from anywhere
  outside your home.
- Port-forwarding disconnects if you close your terminal.
- Even if you opened a port on your router, most home internet plans do not
  give you a static public IP, so the address would change.

You need a way to give your services stable, public URLs like
`grafana.yourdomain.com` and `gitea.yourdomain.com`.

---

## What Cloudflare Tunnel does

Cloudflare Tunnel (formerly called Argo Tunnel) creates a secure, **outbound-only**
connection from your cluster to Cloudflare's global network. Here is the flow:

```
┌────────────────┐         ┌───────────────────┐         ┌─────────────┐
│  Your browser  │──HTTPS──│  Cloudflare Edge   │◄─tunnel─│  Your Pi    │
│  (anywhere)    │         │  (their servers)   │         │  cluster    │
└────────────────┘         └───────────────────┘         └─────────────┘
                                                           cloudflared
                                                           connects OUT
                                                           to Cloudflare
```

Key points:

- **No port forwarding** -- you do not open any ports on your router.
- **No public IP needed** -- the tunnel is outbound from your cluster.
- **Automatic HTTPS** -- Cloudflare handles TLS certificates for you.
- **Free** -- Cloudflare Tunnel is included in the free plan, no credit card
  required.

A small program called `cloudflared` runs as a pod in your cluster. It
maintains a persistent connection to Cloudflare's edge. When someone visits
`grafana.yourdomain.com`, Cloudflare routes the request through the tunnel to
`cloudflared`, which forwards it to the right service inside your cluster.

---

## Prerequisites

Before starting, you need:

- [ ] A **domain name** you own (e.g., `yourdomain.com`). You can buy one from
  any registrar (Cloudflare, Namecheap, Google Domains, etc.). Cheap TLDs like
  `.dev` or `.xyz` cost a few dollars per year.
- [ ] A **Cloudflare account** -- sign up free at
  [dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up).
- [ ] Your domain's **DNS must be managed by Cloudflare** (we will set this up
  in Step 1).

---

## Step 1 -- Add your domain to Cloudflare

If you already manage your domain's DNS through Cloudflare, skip to Step 2.

1. Log in to the [Cloudflare dashboard](https://dash.cloudflare.com/).
2. Click **Add a site** and enter your domain name (e.g., `yourdomain.com`).
3. Select the **Free** plan and click **Continue**.
4. Cloudflare will scan your existing DNS records. Review them and click
   **Continue**.
5. Cloudflare will give you two **nameservers** (e.g.,
   `ada.ns.cloudflare.com` and `bob.ns.cloudflare.com`).
6. Go to your domain registrar (where you bought the domain) and **change the
   nameservers** to the two Cloudflare gave you.
7. Wait for the nameserver change to propagate. This can take a few minutes to
   48 hours, but usually happens within an hour.

### What just happened?

You told the internet "Cloudflare is now in charge of DNS for my domain." All
DNS queries for `yourdomain.com` will now go to Cloudflare's servers, which
means Cloudflare can route traffic to your tunnel.

---

## Step 2 -- Install cloudflared on your Mac

`cloudflared` is the CLI tool for managing Cloudflare Tunnels. Install it with
Homebrew:

```bash
brew install cloudflared
```

Verify:

```bash
cloudflared --version
```

---

## Step 3 -- Authenticate with Cloudflare

Log in to your Cloudflare account from the CLI:

```bash
cloudflared tunnel login
```

This opens a browser window. Select the domain you added in Step 1 and
authorize the connection.

### What just happened?

`cloudflared` saved a certificate file at `~/.cloudflared/cert.pem`. This
certificate proves you own the domain and gives the CLI permission to create
tunnels for it.

---

## Step 4 -- Create a tunnel

Create a tunnel named `pi-k3s`:

```bash
cloudflared tunnel create pi-k3s
```

You will see output like:

```
Tunnel credentials written to /Users/yourname/.cloudflared/<TUNNEL-ID>.json.
Created tunnel pi-k3s with id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Save that tunnel ID** -- you will need it in the next steps. Also note the
path to the credentials JSON file.

### What just happened?

Cloudflare registered a new tunnel in your account. The credentials JSON file
contains a secret that lets `cloudflared` connect to this specific tunnel. Think
of it like an API key for the tunnel.

---

## Step 5 -- Create a Kubernetes secret from the tunnel credentials

Your cluster needs the tunnel credentials to run `cloudflared`. Create a
Kubernetes secret from the JSON file:

```bash
kubectl create namespace cloudflare
```

```bash
kubectl create secret generic cloudflare-tunnel-credentials \
  --namespace cloudflare \
  --from-file=credentials.json=/Users/yourname/.cloudflared/<TUNNEL-ID>.json
```

Replace `<TUNNEL-ID>` with the actual tunnel ID from Step 4 (the long UUID).

### What just happened?

You stored the tunnel credentials inside Kubernetes as a secret. The
`cloudflared` pod will mount this secret and use it to authenticate with
Cloudflare. The credentials never leave your cluster.

---

## Step 6 -- Configure DNS records

Create CNAME records that point your subdomains to the tunnel. Replace
`<TUNNEL-ID>` with your tunnel ID:

```bash
cloudflared tunnel route dns pi-k3s grafana.yourdomain.com
cloudflared tunnel route dns pi-k3s gitea.yourdomain.com
```

### What just happened?

Each command created a CNAME record in Cloudflare's DNS:

- `grafana.yourdomain.com` -> `<TUNNEL-ID>.cfargotunnel.com`
- `gitea.yourdomain.com` -> `<TUNNEL-ID>.cfargotunnel.com`

When someone visits `grafana.yourdomain.com`, DNS resolves to Cloudflare's
network, which knows to route the traffic through your tunnel.

---

## Step 7 -- Deploy cloudflared in the cluster

Now deploy the `cloudflared` pod and its configuration:

```bash
make cloudflare
```

This playbook deploys:

1. A **ConfigMap** with the `cloudflared` configuration -- this tells
   `cloudflared` which hostnames map to which internal services:
   - `grafana.yourdomain.com` -> `http://grafana.monitoring.svc.cluster.local:80`
   - `gitea.yourdomain.com` -> `http://gitea-http.gitea.svc.cluster.local:3000`

2. A **Deployment** running the `cloudflared` container -- it connects outbound
   to Cloudflare using the tunnel credentials and waits for traffic.

3. **Traefik IngressRoutes** that route incoming tunnel traffic to the correct
   services inside the cluster.

> **Note:** You will need to edit the configuration files in `k8s/cloudflare/`
> to replace `yourdomain.com` with your actual domain name before running
> `make cloudflare`.

---

## Step 8 -- Verify

Check that `cloudflared` is running:

```bash
kubectl get pods -n cloudflare
```

You should see:

```
NAME                           READY   STATUS    RESTARTS   AGE
cloudflared-xxxxxxxxxx-xxxxx   1/1     Running   0          1m
```

Now the moment of truth -- open your browser and visit:

```
https://grafana.yourdomain.com
```

You should see the Grafana login page, served over HTTPS with a valid
certificate, accessible from anywhere in the world.

Try Gitea too:

```
https://gitea.yourdomain.com
```

### What just happened?

The full chain is now:

1. Your browser asks DNS for `grafana.yourdomain.com`.
2. Cloudflare DNS responds with an address on Cloudflare's network.
3. Your browser connects to Cloudflare over HTTPS.
4. Cloudflare routes the request through the tunnel to `cloudflared` running in
   your cluster.
5. `cloudflared` forwards the request to the Grafana service.
6. Grafana responds, and the response flows back through the same path.

All of this happens in milliseconds, and your home IP address is never exposed.

---

## Security: Adding authentication with Cloudflare Access

Right now, anyone who knows the URL can reach your Grafana and Gitea. Grafana
and Gitea have their own login pages, but you can add an extra layer of
protection using **Cloudflare Access** (also free).

Cloudflare Access puts an authentication page in front of your services. You
can require:

- An email one-time code (no extra accounts needed)
- Google/GitHub/other OAuth login
- IP address restrictions

To set it up:

1. In the Cloudflare dashboard, go to **Zero Trust** > **Access** >
   **Applications**.
2. Click **Add an application** > **Self-hosted**.
3. Enter the subdomain (e.g., `grafana.yourdomain.com`).
4. Configure an identity provider (email OTP is the easiest to start with).
5. Set a policy (e.g., allow only your email address).

This is optional but recommended, especially for services like Grafana that
have powerful admin capabilities.

---

## Troubleshooting

**cloudflared pod in CrashLoopBackOff:**

Check the logs:

```bash
kubectl logs -n cloudflare deployment/cloudflared --tail=30
```

Common issues:
- Wrong tunnel credentials -- re-create the secret from Step 5.
- Configuration YAML has a typo -- check the ConfigMap.

**DNS not resolving:**

Verify the CNAME records exist:

```bash
dig grafana.yourdomain.com
```

If you see `NXDOMAIN`, the DNS record was not created. Re-run the
`cloudflared tunnel route dns` commands from Step 6.

**"Bad gateway" or "502" errors:**

The tunnel is working but `cloudflared` cannot reach the backend service. Check
that the service names in the ConfigMap match what is actually running:

```bash
kubectl get svc -n monitoring
kubectl get svc -n gitea
```

---

## Checklist

Before moving on, confirm:

- [ ] Your domain is managed by Cloudflare (nameservers changed)
- [ ] `cloudflared tunnel list` shows your `pi-k3s` tunnel
- [ ] `kubectl get pods -n cloudflare` shows cloudflared Running
- [ ] You can reach `https://grafana.yourdomain.com` from your browser
- [ ] You can reach `https://gitea.yourdomain.com` from your browser
- [ ] Both sites load over HTTPS with a valid certificate

---

## Next step

[10 - Destroy and Rebuild: Testing Your Automation](10-destroy-rebuild.md)
