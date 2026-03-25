# 00 - Prerequisites: Setting Up Your Workstation

## What you'll learn

- The mental model of how your Mac controls the Raspberry Pi cluster
- How to install every tool you need on macOS
- How to set up SSH so your Mac can talk to all 4 Pis without a password
- What each tool does and why you need it

---

## The mental model

Before we install anything, here is the big picture:

```
┌──────────────────┐         SSH          ┌─────────────────┐
│                  │ ───────────────────►  │  pi-k3s-1       │
│  Your Mac        │ ───────────────────►  │  pi-k3s-2       │
│  (workstation)   │ ───────────────────►  │  pi-k3s-3       │
│                  │ ───────────────────►  │  pi-k3s-4       │
└──────────────────┘                       └─────────────────┘
   "control machine"                         "managed nodes"
```

Your Mac is the **control machine**. You will never need to plug a keyboard or
monitor into a Pi again after the initial flash. Every command, every
configuration change, every software install on the Pis will happen from your
Mac over SSH -- either manually or (much better) through Ansible.

The Pis are the **managed nodes**. They sit on your network, run Linux, and
wait for instructions.

---

## Step 1 -- Install Homebrew

Homebrew is the package manager for macOS. If you already have it, skip ahead.

Open **Terminal** (press `Cmd + Space`, type `Terminal`, hit Enter) and paste:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the prompts. When it finishes, close and reopen Terminal, then verify:

```bash
brew --version
```

You should see something like `Homebrew 4.x.x`.

---

## Step 2 -- Install the tools

Run this single command to install everything you need:

```bash
brew install ansible kubectl helm k9s age sops
```

This will take a few minutes. When it finishes, verify each tool is available:

```bash
ansible --version
kubectl version --client
helm version
k9s version
age --version
sops --version
```

### What each tool does

| Tool | One-sentence explanation |
|------|------------------------|
| **ansible** | Automates running commands on remote machines over SSH so you don't have to do it by hand. |
| **kubectl** | The command-line tool for talking to a Kubernetes cluster (checking status, deploying apps, reading logs). |
| **helm** | A package manager for Kubernetes -- it installs pre-packaged applications (called "charts") into your cluster. |
| **k9s** | A terminal UI that lets you browse your Kubernetes cluster interactively, like a file manager for your cluster. |
| **age** | A simple file encryption tool -- you will use it to encrypt secrets (passwords, API keys) before committing them to git. |
| **sops** | Works with age to encrypt/decrypt only the *values* in YAML files, so you can safely store secrets in your repository. |

---

## Step 3 -- Generate an SSH key

SSH keys let your Mac prove its identity to the Pis without typing a password
every time. Think of it like a house key instead of a combination lock.

Check if you already have a key:

```bash
ls ~/.ssh/id_ed25519.pub
```

If that prints a path, you already have a key and can skip to Step 4. If it
says "No such file", generate one:

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
```

**What the prompts mean:**

- **"Enter file in which to save the key"** -- press Enter to accept the default (`~/.ssh/id_ed25519`).
- **"Enter passphrase"** -- you can press Enter for no passphrase (convenient for automation) or type one for extra security. Either is fine for a home lab.

### What just happened?

Two files were created:

- `~/.ssh/id_ed25519` -- your **private** key. Never share this.
- `~/.ssh/id_ed25519.pub` -- your **public** key. This is what you copy to the Pis.

---

## Step 4 -- Copy your SSH key to all 4 Pis

For each Pi, run `ssh-copy-id`. Replace the IP addresses with your actual Pi
IPs (you will set these up in [02-network-setup.md](02-network-setup.md)):

```bash
ssh-copy-id ubuntu@192.168.1.101
ssh-copy-id ubuntu@192.168.1.102
ssh-copy-id ubuntu@192.168.1.103
ssh-copy-id ubuntu@192.168.1.104
```

Each time you will be asked for the password. If you have not changed it yet,
the default Ubuntu password is `ubuntu` (you will be forced to change it on
first login -- see [01-flash-ubuntu.md](01-flash-ubuntu.md)).

### What just happened?

`ssh-copy-id` read your public key (`~/.ssh/id_ed25519.pub`) and appended it
to the `~/.ssh/authorized_keys` file on each Pi. From now on, SSH uses the key
instead of a password.

---

## Step 5 -- Verify SSH access

Test that passwordless SSH works to every node:

```bash
ssh ubuntu@192.168.1.101 "hostname"
ssh ubuntu@192.168.1.102 "hostname"
ssh ubuntu@192.168.1.103 "hostname"
ssh ubuntu@192.168.1.104 "hostname"
```

Each command should print the hostname of that Pi (e.g., `pi-k3s-1`) and
return you to your Mac's prompt with no password prompt. If any of them ask for
a password, go back to Step 4 for that node.

---

## Checklist

Before moving on, confirm:

- [ ] `brew --version` works
- [ ] `ansible --version` works
- [ ] `kubectl version --client` works
- [ ] `helm version` works
- [ ] `k9s version` works
- [ ] `age --version` works
- [ ] `sops --version` works
- [ ] You can SSH to all 4 Pis without a password

---

## Next step

[01 - Flash Ubuntu onto your CM5 modules](01-flash-ubuntu.md)
