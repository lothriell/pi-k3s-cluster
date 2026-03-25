# 03 - Install and Understand Ansible

## What you'll learn

- What Ansible is and why it exists (in plain language)
- How to verify it is installed
- The 5 key Ansible concepts you need to know
- How Ansible connects to your Pis
- How to test your first Ansible command
- The Ansible file structure used in this project
- Common commands you will use throughout this project

---

## What is Ansible?

Imagine you need to update a configuration file on all 4 of your Pis. Without
Ansible, you would:

1. SSH into Pi 1, edit the file, exit.
2. SSH into Pi 2, edit the file, exit.
3. SSH into Pi 3, edit the file, exit.
4. SSH into Pi 4, edit the file, exit.

That is tedious with 4 machines and impossible with 400.

**Ansible automates this.** You write a YAML file that says "make sure this line
is in this file on these machines", and Ansible SSHes into all of them and does
it for you -- in parallel.

That is really all it is: **a tool that SSHes into machines and runs commands
for you, based on instructions you write in YAML files.**

There is no software to install on the Pis. Ansible just needs SSH access and
Python on the remote machine (Ubuntu comes with Python).

---

## Step 1 -- Verify Ansible is installed

You installed Ansible in [00-prerequisites.md](00-prerequisites.md). Verify:

```bash
ansible --version
```

You should see output like:

```
ansible [core 2.x.x]
  config file = None
  ...
  python version = 3.x.x
```

If this does not work, install it:

```bash
brew install ansible
```

---

## Step 2 -- Understand the 5 key concepts

Here are the only Ansible concepts you need to know for this project. Do not
worry about memorizing them -- you will see them in action soon.

### 1. Inventory (the "who")

An inventory is a file that lists the machines Ansible should manage. It is
just a YAML file with hostnames and IP addresses.

```yaml
# This tells Ansible: "I have 4 machines, here are their addresses"
all:
  children:
    servers:
      hosts:
        pi-k3s-1:
          ansible_host: 192.168.1.101
    agents:
      hosts:
        pi-k3s-2:
          ansible_host: 192.168.1.102
```

### 2. Tasks (the "what")

A task is a single action, like "install this package" or "copy this file".

```yaml
- name: Install curl
  apt:
    name: curl
    state: present
```

Reading this aloud: "Make sure the package `curl` is present (installed)."

### 3. Playbooks (the "recipe")

A playbook is a YAML file containing a list of tasks. It says "on these
machines, do these things in this order".

```yaml
- hosts: all           # Run on all machines in the inventory
  become: true         # Use sudo
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes

    - name: Install curl
      apt:
        name: curl
        state: present
```

### 4. Roles (the "cookbook")

A role is a reusable bundle of tasks, files, and templates organized into a
standard folder structure. Instead of one giant playbook, you break things into
roles like `common`, `k3s_server`, `k3s_agent`.

Think of a playbook as a recipe and a role as a chapter in a cookbook.

### 5. Handlers (the "if something changed, then...")

A handler is a task that only runs when it is triggered by another task. The
most common use is restarting a service after changing its config file.

```yaml
tasks:
  - name: Update sshd config
    copy:
      src: sshd_config
      dest: /etc/ssh/sshd_config
    notify: restart sshd      # <-- triggers the handler below

handlers:
  - name: restart sshd
    service:
      name: sshd
      state: restarted
```

This means: "Copy the sshd config file. If the file actually changed, restart
sshd. If it was already correct, do nothing."

---

## Step 3 -- How Ansible connects to your Pis

Ansible uses **SSH** -- the same SSH you set up in
[00-prerequisites.md](00-prerequisites.md). That is why we generated keys and
ran `ssh-copy-id` earlier. Ansible will:

1. Read the inventory to find out which machines to connect to.
2. Open SSH connections to each machine (using your SSH key).
3. Copy small Python scripts to the remote machine.
4. Run those scripts.
5. Collect the results and show you what happened.

You do not need to install anything on the Pis for this to work. If you can
`ssh ubuntu@pi-k3s-1`, then Ansible can reach it.

---

## Step 4 -- Test your connection with Ansible

Let's run your first Ansible command. This uses the `ping` module, which is
Ansible's way of saying "can I connect and run Python on this machine?"

> **Note:** This is NOT a network ping (ICMP). It is an Ansible module that
> SSHes in and confirms everything works.

First, navigate to the project directory:

```bash
cd ~/claude/kubernetes
```

If the inventory file exists at `ansible/inventory/hosts.yml`, run:

```bash
ansible all -i ansible/inventory/hosts.yml -m ping
```

If the inventory file does not exist yet, you can test with a quick one-liner
(replace IPs with yours):

```bash
ansible all -i '192.168.1.101,192.168.1.102,192.168.1.103,192.168.1.104,' \
  -u ubuntu -m ping
```

(Note the trailing comma -- Ansible needs it when passing a list directly.)

### Successful output looks like this

```
pi-k3s-1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
pi-k3s-2 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
pi-k3s-3 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
pi-k3s-4 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

### What just happened?

Ansible read the inventory, SSHed into all 4 Pis simultaneously, ran a tiny
Python script that replied "pong", and reported back. The `"changed": false`
means Ansible did not modify anything on the system (it was just a test).

### Troubleshooting

| Problem | Fix |
|---------|-----|
| `UNREACHABLE! ... Permission denied` | SSH key not copied. Re-run `ssh-copy-id ubuntu@<ip>`. |
| `UNREACHABLE! ... Connection timed out` | Wrong IP or Pi is off. Check with `ping <ip>`. |
| `UNREACHABLE! ... No route to host` | Network issue. Make sure your Mac and Pis are on the same subnet. |
| `FAILED! ... /usr/bin/python3: not found` | Unlikely on Ubuntu 24.04, but fix with `ssh ubuntu@<ip> "sudo apt install python3"`. |

---

## Step 5 -- Understand this project's Ansible structure

This project organizes Ansible files like this:

```
ansible/
├── inventory/
│   └── hosts.yml           # The list of your Pis and their IPs
├── playbooks/
│   └── (playbook files)    # The "recipes" that run against your Pis
└── roles/
    └── (role directories)  # Reusable groups of tasks
```

| Path | What it is |
|------|-----------|
| `ansible/inventory/hosts.yml` | Your inventory -- edit this with your real IPs |
| `ansible/playbooks/` | Playbooks you will run to set up K3s, deploy apps, etc. |
| `ansible/roles/` | Roles that playbooks reference (common setup, K3s install, etc.) |

When you run a playbook, the command looks like:

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/some-playbook.yml
```

This means: "Using the machines listed in `hosts.yml`, run the tasks in
`some-playbook.yml`."

---

## Step 6 -- Common Ansible commands

Here is a reference card of commands you will use in this project. You do not
need to memorize them -- come back here when you need them.

### Run a playbook

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml
```

### Run a playbook with verbose output (for debugging)

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml -v
```

Add more `v`s for more detail: `-vv`, `-vvv`.

### Ping all hosts (test connectivity)

```bash
ansible all -i ansible/inventory/hosts.yml -m ping
```

### Run a one-off command on all hosts

```bash
ansible all -i ansible/inventory/hosts.yml -a "uptime"
```

### Run a command on just the server nodes

```bash
ansible servers -i ansible/inventory/hosts.yml -a "uptime"
```

### Run a command on just the agent nodes

```bash
ansible agents -i ansible/inventory/hosts.yml -a "uptime"
```

### Check what a playbook would do (dry run)

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml --check
```

This runs in "check mode" -- Ansible reports what it **would** change without
actually changing anything. Useful for previewing before committing.

### List all hosts in your inventory

```bash
ansible-inventory -i ansible/inventory/hosts.yml --list
```

---

## Checklist

Before moving on, confirm:

- [ ] `ansible --version` works
- [ ] You understand the 5 concepts: inventory, tasks, playbooks, roles, handlers
- [ ] `ansible all -i ansible/inventory/hosts.yml -m ping` returns SUCCESS for all 4 nodes
- [ ] You know where the Ansible files live in this project

---

## Next step

You are now ready to use Ansible to automate the cluster setup. The next step
will walk you through running the playbooks that install K3s on your Pis and
turn them into a working Kubernetes cluster.
