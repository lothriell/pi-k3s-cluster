# 02 - Network Setup: Static IPs for Your Cluster

## What you'll learn

- Why a Kubernetes cluster needs static IPs
- How to assign fixed IPs in your UniFi Gateway
- How to find MAC addresses for your Pis
- How to set up your Mac so you can reach each Pi by name
- How to verify full network connectivity

---

## Why static IPs matter

When a device connects to your network, your router gives it an IP address via
DHCP. The problem is that DHCP can assign a **different** IP every time the
device reboots. That is fine for a phone, but a Kubernetes cluster needs nodes
to always find each other at the same address.

There are two ways to fix this:

1. **Static DHCP mappings (recommended)** -- Tell your router "whenever you see
   this device, always give it the same IP." The Pi still uses DHCP, but the
   router always hands out the same address.
2. **Static IP on the Pi itself** -- Configure the Pi to hardcode its own IP.
   This works but is more fragile (if you change subnets, you have to
   reconfigure every node).

We will use option 1 because it keeps all IP management in one place (your
UniFi dashboard).

---

## Step 1 -- Choose an IP scheme

Pick 4 consecutive IPs in your subnet that are **outside your DHCP range** (or
inside the range but reserved). Here is an example:

| Hostname | IP Address | Role |
|----------|-----------|------|
| `rpi-k3s-1` | `10.0.0.11` | K3s server (control plane) |
| `rpi-k3s-2` | `10.0.0.12` | K3s agent (worker) |
| `rpi-k3s-3` | `10.0.0.13` | K3s agent (worker) |
| `rpi-k3s-4` | `10.0.0.14` | K3s agent (worker) |

> **Important:** These are example IPs. Your subnet may be `10.0.0.x` or
> `192.168.0.x` or something else entirely. Check your UniFi dashboard under
> **Settings > Networks** to see your actual subnet. Adjust the IPs accordingly.

To check your Mac's current subnet:

```bash
ifconfig en0 | grep "inet "
```

This will show something like `inet 10.69.0.x netmask 0xffffff00`. The
first three groups (`192.168.1`) are your subnet.

---

## Step 2 -- Find the MAC addresses

Every network device has a unique MAC address (like a serial number for the
network card). You need these to create the static mappings.

### Option A: From each Pi

SSH into each Pi and run:

```bash
ip link show eth0
```

Look for the line containing `link/ether` followed by something like
`dc:a6:32:xx:xx:xx`. That is the MAC address.

Example output:

```
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    link/ether dc:a6:32:12:34:56 brd ff:ff:ff:ff:ff:ff
```

The MAC address here is `dc:a6:32:12:34:56`.

### Option B: From the UniFi dashboard

1. Open the UniFi dashboard (usually at `https://unifi.ui.com` or your local controller address).
2. Go to **Client Devices**.
3. Find each Pi (look for the hostnames `rpi-k3s-1` through `rpi-k3s-4`, or look for new devices).
4. Click on a Pi to see its details -- the MAC address is listed there.

Record all 4 MAC addresses:

```
rpi-k3s-1: ___:___:___:___:___:___
rpi-k3s-2: ___:___:___:___:___:___
rpi-k3s-3: ___:___:___:___:___:___
rpi-k3s-4: ___:___:___:___:___:___
```

---

## Step 3 -- Create static DHCP mappings in UniFi

1. Open the **UniFi dashboard**.
2. Navigate to **Settings** (gear icon) > **Networks**.
3. Click on your **Default** network (or whichever network the Pis are on).
4. Scroll down to **DHCP** settings.
5. Under **DHCP Service Management**, look for **Static Mappings** (it may also be labeled "Fixed IP" or "DHCP Reservations" depending on your UniFi version).
6. Click **Create New** (or **Add Entry**).
7. Fill in:
   - **Name:** `rpi-k3s-1`
   - **MAC Address:** the MAC address from Step 2
   - **IP Address:** `10.0.0.11` (or your chosen IP)
8. Click **Save** or **Apply**.
9. Repeat for all 4 nodes.

### What just happened?

You told your UniFi Gateway: "Whenever a device with MAC address
`dc:a6:32:xx:xx:xx` asks for an IP via DHCP, always give it `10.0.0.11`."
The Pi does not know or care -- it just asks for an IP like normal and always
gets the same one.

---

## Step 4 -- Apply the new IPs

The static mappings take effect on the next DHCP lease renewal. To force it
immediately, reboot each Pi:

```bash
ssh myuser@<current-ip-of-pi> "sudo reboot"
```

Wait about 60 seconds, then check from your Mac:

```bash
ping -c 3 10.0.0.11
ping -c 3 10.0.0.12
ping -c 3 10.0.0.13
ping -c 3 10.0.0.14
```

All 4 should respond.

---

## Step 5 -- (Optional) Add DNS entries in UniFi

If you want to be able to type `rpi-k3s-1` instead of `10.0.0.11`, you can
add local DNS records:

1. In the UniFi dashboard, go to **Settings** > **Networks** > **DNS**.
2. Under **DNS Records** (or **Local DNS Entries**), add:
   - `rpi-k3s-1` -> `10.0.0.11`
   - `rpi-k3s-2` -> `10.0.0.12`
   - `rpi-k3s-3` -> `10.0.0.13`
   - `rpi-k3s-4` -> `10.0.0.14`
3. Save.

> The exact location of this setting varies by UniFi OS version. If you cannot
> find it, the `/etc/hosts` approach in Step 6 works just as well.

---

## Step 6 -- Update /etc/hosts on your Mac

This is the simplest way to use hostnames instead of IPs from your workstation.
Open the file:

```bash
sudo nano /etc/hosts
```

Add these lines at the bottom (adjust IPs to match yours):

```
# Raspberry Pi K3s Cluster
10.0.0.11   rpi-k3s-1
10.0.0.12   rpi-k3s-2
10.0.0.13   rpi-k3s-3
10.0.0.14   rpi-k3s-4
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

### Verify it works

```bash
ping -c 2 rpi-k3s-1
ping -c 2 rpi-k3s-2
ping -c 2 rpi-k3s-3
ping -c 2 rpi-k3s-4
```

And SSH by hostname:

```bash
ssh myuser@rpi-k3s-1 "hostname"
```

Should print `rpi-k3s-1`.

---

## Step 7 -- Note about Ansible inventory

Later in this project, you will see an Ansible inventory file at
`ansible/inventory/hosts.yml` that lists your Pi IP addresses. It will contain
placeholder IPs like `10.0.0.11`. **You need to replace those with your
actual IPs.**

This is what the inventory looks like (you do not need to create it now -- it
already exists or will be created in a later step):

```yaml
all:
  children:
    servers:
      hosts:
        rpi-k3s-1:
          ansible_host: 10.0.0.11    # <-- replace with your actual IP
    agents:
      hosts:
        rpi-k3s-2:
          ansible_host: 10.0.0.12    # <-- replace with your actual IP
        rpi-k3s-3:
          ansible_host: 10.0.0.13    # <-- replace with your actual IP
        rpi-k3s-4:
          ansible_host: 10.0.0.14    # <-- replace with your actual IP
```

When you get to that step, just swap in the IPs you chose above.

---

## Checklist

Before moving on, confirm:

- [ ] All 4 Pis have static IPs assigned in UniFi
- [ ] You can ping all 4 IPs from your Mac
- [ ] You can SSH to all 4 using `ssh myuser@<ip>`
- [ ] (Optional) Hostnames work via `/etc/hosts` or UniFi DNS
- [ ] You have written down your IP-to-hostname mapping somewhere safe

---

## Next step

[03 - Install and Understand Ansible](03-install-ansible.md)
