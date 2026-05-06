# Trusting the homielab internal CA

cert-manager mints TLS certs for every `*.<local-domain>` service from a
private root CA stored in-cluster. Each device that visits these URLs
needs to trust the root CA once. After that, all browsers / Bitwarden
clients / `curl` etc. accept the leaf certs without prompts.

The CA is a 10-year ECDSA root, generated on first `make cert-manager`.
If you rebuild the cluster or rotate the CA, re-import on every device.

## 1. Export the CA cert from the cluster

```bash
make trust-ca-export
# writes /tmp/homielab-ca.crt and prints subject + issuer + dates
```

The file is a PEM `BEGIN CERTIFICATE`. Copy it to the device that needs
to trust it (Syncthing, AirDrop, scp, USB stick — your call).

## 2. Trust on each device

### macOS (Mac mini, MacBook Air, etc.)

**Interactive macs (you have a terminal session as your admin user):**

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/homielab-ca.crt
```

Verify:

```bash
security find-certificate -c homielab-internal-ca /Library/Keychains/System.keychain
curl -v https://vault.<local-domain> 2>&1 | grep -E 'SSL certificate|subject|issuer'
```

**Headless / fleet-managed Macs** (e.g. macmini reached over SSH only):
the command above fails with `SecTrustSettingsSetTrustSettings: The
authorization was denied since no user interaction was possible`. macOS
Sonoma+ requires GUI auth for `com.apple.trust-settings.admin`, and even
flipping the auth right via `security authorizationdb write … allow`
returns `NO (-60005)` because that write itself needs the same right.

The supported headless paths are:
1. **MDM** (Jamf Pro, Kandji, etc.) — out of scope for a homelab.
2. **mobileconfig profile** — distribute via Ansible, finish with one GUI
   approval per host.

Use `make trust-ca-push` (or `ansible-playbook ansible/playbooks/16-trust-homielab-ca.yml`)
to deliver `homielab-ca.crt` AND `homielab-internal-ca.mobileconfig`
to every host in `macos_nodes`. Then on each Mac (one-time):

```
open /tmp/homielab-internal-ca.mobileconfig
# → System Settings → Privacy & Security → Profiles →
#   homielab internal CA → Install → admin auth
```

GUI alternative: open `homielab-ca.crt` in Keychain Access → drag into
the **System** keychain → double-click the entry → expand "Trust" →
"When using this certificate" → **Always Trust**.

### Windows 11 (PC)

**Option 1 — Headless via WSL+SSH (recommended for fleet management):**

If the PC has WSL + an SSH server reachable from the Ansible controller,
add it to `windows_wsl_nodes` in `ansible/inventory/hosts.yml` and run
`make trust-ca-push`. The playbook ships the cert through WSL, then uses
WSL interop (`powershell.exe` from inside WSL) to call:

```powershell
Import-Certificate `
  -FilePath C:\Users\<winuser>\homielab-ca.crt `
  -CertStoreLocation Cert:\CurrentUser\Root
```

Scope is `CurrentUser\Root` — per-user trust, no UAC. Chrome / Edge /
native `curl` for that user trust the CA. Firefox uses NSS (see below).
For system-wide trust (`Cert:\LocalMachine\Root`) UAC blocks any headless
path; do that one manually with admin PowerShell:

```powershell
Import-Certificate -FilePath C:\Users\you\homielab-ca.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

**Option 2 — Manual:**

Double-click `homielab-ca.crt` → **Install Certificate** → **Local
Machine** → **Place all certificates in the following store** → Browse
→ **Trusted Root Certification Authorities** → Finish.

Verify in browser: visit `https://argocd.<local-domain>`. Lock icon, no
warning. Firefox uses its own trust store — see "Firefox" below.

### iPadOS / iPhone

iOS splits "install profile" from "trust as root":

1. Send `homielab-ca.crt` to the device (Mail, AirDrop, Files).
2. Open it. iOS prompts to install a configuration profile.
3. Settings → **VPN & Device Management** → Downloaded Profile → tap
   **homielab-internal-ca** → Install (Face ID / passcode).
4. Settings → General → **About** → **Certificate Trust Settings** →
   toggle **homielab-internal-ca** to ON. Confirm the warning.
5. Bitwarden mobile app: Settings → Self-hosted environment → Server URL
   `https://vault.<local-domain>`. Tailscale must be on for the LAN IP to
   resolve.

### Firefox (any OS)

Firefox uses its own NSS store, not the OS trust store.

Settings → search "certificates" → **View Certificates** → **Authorities**
tab → **Import** → pick `homielab-ca.crt` → check **"Trust this CA to
identify websites"** → OK.

## 3. Verify cert-manager owns the leaf certs

```bash
kubectl get certificate -A
kubectl get secret -A | grep -E '(grafana|prometheus|alertmanager|gitea|forgejo|argocd|headlamp|longhorn|open-webui|vaultwarden|authentik|ollama)-local-tls'
```

Each Ingress in `k8s/ingress/local-ingress.yml.j2` triggers a
`Certificate` CR (via cert-manager's ingress-shim controller), which mints
the matching TLS Secret in the same namespace.

If a cert stays in `Issuing`/`False` for more than ~30 seconds:

```bash
kubectl describe certificate -n <ns> <name>-local-tls
kubectl logs -n cert-manager deploy/cert-manager
```

## 4. Rotation / cluster rebuild

The root CA's private key lives in the secret `cert-manager/homielab-ca-tls`
and is part of the Longhorn-backed cluster state — not currently in the
Longhorn backup set, so a cluster nuke regenerates a new CA. After a
rebuild every client needs to be re-trusted (this doc).

To pre-stage for less pain on rebuild, see DR-4: back up the CA secret
to R2 alongside vault.yml.
