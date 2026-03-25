# 04 - Prepare Your Nodes

## What you'll learn

- What "preparing nodes" means and why each step matters
- How to run the preparation playbook with a single command
- How to read Ansible's output so you know what happened
- How to verify everything worked
- How to fix common problems

---

## What does "preparing nodes" mean?

Before you can install Kubernetes (K3s) on your Raspberry Pi CM5 modules, each one needs to be configured in a specific way. Think of it like prepping a room before painting -- you need to lay down drop cloths, tape the trim, and move the furniture before the first brushstroke.

The prepare playbook does all of this automatically on every node (rpi-k3s-1 through rpi-k3s-4). Here is exactly what it does and why:

### 1. Update all system packages

```
apt update && apt upgrade
```

Just like running software updates on your phone. This makes sure every node starts from the same, up-to-date baseline so you don't hit bugs that have already been fixed.

### 2. Set the timezone

Sets every node to the same timezone so log timestamps match up. When something goes wrong at 2:14 AM, you don't want one node saying it happened at 7:14 AM because it thinks it's in London.

### 3. Disable swap

**This one is important.** Swap is when Linux uses disk space as pretend RAM when real RAM runs low. Kubernetes **requires** swap to be turned off. Why? Kubernetes needs to precisely manage how much memory each container gets. If the OS silently starts swapping, containers appear to have memory they don't really have, and the scheduler makes bad decisions. Things get slow and unpredictable.

Your CM5 modules have 16 GB of RAM each -- plenty for a home cluster -- so you won't miss swap.

### 4. Load kernel modules for networking

Loads two Linux kernel modules:

- **`br_netfilter`** -- Lets the Linux bridge (the virtual network switch that connects containers) properly filter network traffic. Without this, network policies and firewalling inside the cluster won't work.
- **`overlay`** -- Enables overlay networking, which is how containers get their own isolated filesystem layers.

These are loaded now *and* configured to load automatically on every reboot.

### 5. Enable IP forwarding

```
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
```

By default, Linux ignores network packets that aren't addressed to it. But a Kubernetes node has to **forward** packets between containers, between nodes, and out to the internet. Enabling IP forwarding tells Linux "yes, pass those packets along." Without this, pods on one node can't talk to pods on another node.

### 6. Install common packages

Installs useful utilities that K3s or your day-to-day administration will need, things like `curl`, `apt-transport-https`, `open-iscsi` (for storage), and other dependencies. This way you won't hit a missing-package error halfway through the K3s install.

---

## How to run it

The simplest way:

```bash
make prepare
```

That's it. One command.

If you want to see the full Ansible command that `make prepare` runs (or if you want to run it manually):

```bash
ansible-playbook -i inventory/hosts.yml playbooks/prepare-nodes.yml
```

Both do exactly the same thing.

### What happens when you hit Enter

Ansible will:

1. Connect to all four nodes over SSH (in parallel)
2. Run every task in the playbook on each node
3. Print a play-by-play of what it did
4. Show a summary at the end

This typically takes 2-5 minutes depending on how many packages need updating.

---

## Understanding the output

While the playbook runs, you'll see a stream of output. Here's how to read it.

### During the run

Each task prints its name and a status for every node:

```
TASK [Update apt package cache] ************************************************
ok: [rpi-k3s-1]
ok: [rpi-k3s-2]
changed: [rpi-k3s-3]
ok: [rpi-k3s-4]
```

### The final summary (PLAY RECAP)

At the very end, you'll see something like this:

```
PLAY RECAP *********************************************************************
rpi-k3s-1   : ok=12   changed=5    unreachable=0    failed=0    skipped=0
rpi-k3s-2   : ok=12   changed=5    unreachable=0    failed=0    skipped=0
rpi-k3s-3   : ok=12   changed=5    unreachable=0    failed=0    skipped=0
rpi-k3s-4   : ok=12   changed=5    unreachable=0    failed=0    skipped=0
```

Here's what each column means:

| Status | Meaning |
|---|---|
| **ok** | The task ran and the node was already in the desired state. Nothing needed to change. This is perfectly normal and good. |
| **changed** | The task ran and actually made a change on the node (installed a package, modified a file, etc.). Expected on the first run. |
| **unreachable** | Ansible could not connect to the node at all. The node is either off, has the wrong IP, or SSH isn't working. **This is a problem.** |
| **failed** | Ansible connected but a task failed (e.g., a package couldn't install, a file couldn't be written). **This is a problem.** |
| **skipped** | The task had a condition that wasn't met, so it was intentionally skipped. Normal and fine. |

**The ideal outcome:** zero `unreachable` and zero `failed` for all four nodes.

**If you run it a second time**, you'll see mostly `ok` and very few `changed`. That's Ansible being *idempotent* -- it only changes things that need changing. Running the same playbook twice won't break anything.

---

## How to verify it worked

You don't have to trust the output blindly. SSH into any node and check for yourself.

### Check that swap is off

```bash
ssh rpi-k3s-1
free -h
```

You should see `0B` across the entire Swap row:

```
              total        used        free      shared  buff/cache   available
Mem:           15Gi       1.2Gi        12Gi        10Mi       1.8Gi        13Gi
Swap:            0B          0B          0B
```

If the Swap row shows anything other than `0B`, swap was not properly disabled.

### Check kernel modules are loaded

```bash
lsmod | grep br_netfilter
```

You should see output like:

```
br_netfilter           32768  0
bridge                307200  1 br_netfilter
```

If you see no output at all, the module didn't load.

Also check overlay:

```bash
lsmod | grep overlay
```

```
overlay               151552  0
```

### Check IP forwarding is on

```bash
sysctl net.ipv4.ip_forward
```

Should return:

```
net.ipv4.ip_forward = 1
```

---

## Troubleshooting

### "unreachable" for one or more nodes

**Symptom:** The PLAY RECAP shows `unreachable=1` for a node.

**Cause:** Ansible can't SSH into that node.

**Fix -- check these in order:**

1. **Is the node powered on?** Check the LED on the IO board.

2. **Can you ping it?**
   ```bash
   ping rpi-k3s-1
   ```
   If this fails, the node is either off or has a different IP/hostname than what's in your inventory file.

3. **Can you SSH manually?**
   ```bash
   ssh rpi-k3s-1
   ```
   If this asks for a password, your SSH key isn't set up correctly for that node. Go back to your node setup steps and ensure your public key is in `~/.ssh/authorized_keys` on the node.

4. **Check your inventory file** (`inventory/hosts.yml`). Make sure the hostname or IP address is correct for the failing node.

### "Permission denied" or "sudo password required"

**Symptom:** Tasks fail with `Missing sudo password` or `Permission denied`.

**Fix:** Make sure the user Ansible connects as has passwordless sudo. On each node:

```bash
ssh rpi-k3s-1
sudo visudo
```

Ensure there's a line like:

```
your-username ALL=(ALL) NOPASSWD: ALL
```

### "failed" on package installation

**Symptom:** A task that installs packages fails with a `dpkg` or `apt` error.

**Fix:**

1. SSH into the failing node.
2. Run the update manually to see the actual error:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```
3. Common cause: another `apt` process is running (maybe an unattended upgrade). Wait a minute and try again:
   ```bash
   # Check if apt is locked
   sudo lsof /var/lib/dpkg/lock-frontend
   ```

### Swap is still showing after the playbook

**Symptom:** `free -h` still shows swap.

**Fix:** Reboot the node and check again:

```bash
ssh rpi-k3s-1
sudo reboot
```

Wait 30 seconds, SSH back in, and run `free -h` again. The playbook disables swap both immediately and on reboot, but occasionally a reboot makes it stick.

---

## What's next?

Your nodes are prepped and ready. Next up: installing K3s and forming your cluster.

**Next step:** [05 - Install K3s](05-install-k3s.md)
