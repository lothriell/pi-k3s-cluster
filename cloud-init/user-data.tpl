#cloud-config
# =============================================================================
# Cloud-init user-data template for Pi K3s cluster nodes
# =============================================================================
# This file is processed by cloud-init on FIRST BOOT ONLY.
# Place it on the boot partition as 'user-data' (no extension).
#
# Variables to replace per node:
#   __HOSTNAME__  - e.g., rpi-k3s-1, rpi-k3s-2, etc.
#
# The flash-node.sh script does this automatically.
# =============================================================================

# --- Identity ----------------------------------------------------------------
hostname: __HOSTNAME__
manage_etc_hosts: true

# --- Timezone / Locale -------------------------------------------------------
timezone: UTC
locale: en_US.UTF-8

# --- Users --------------------------------------------------------------------
# Create both personal (myuser) and automation (ansible) accounts.
# Both get SSH key access. Only ansible gets passwordless sudo.
# Password login is disabled entirely - SSH keys only.
users:
  - name: myuser
    gecos: Personal Account
    groups: adm, sudo, systemd-journal
    shell: /bin/bash
    sudo: "ALL=(ALL:ALL) ALL"
    lock_passwd: false
    # TODO: replace with your hashed password (generate with: mkpasswd -m sha-512)
    passwd: "$6$rounds=4096$randomsalt$REPLACE_WITH_HASHED_PASSWORD"
    ssh_authorized_keys:
      - __SSH_PUBKEY__

  - name: ansible
    gecos: Ansible Automation Service Account
    groups: adm, sudo, systemd-journal
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - __SSH_PUBKEY__

# --- SSH Hardening ------------------------------------------------------------
ssh_pwauth: false
disable_root: true

# --- Packages -----------------------------------------------------------------
# Don't upgrade on first boot - Ansible manages updates deliberately
package_update: true
package_upgrade: false
packages:
  - python3
  - curl
  - wget

# --- NTP ----------------------------------------------------------------------
# Use plain NTP (port 123/udp) instead of Ubuntu's NTS default (port 4460/tcp).
# NTS TLS handshakes frequently time out, leaving Pis without time sync.
# Pi CM5 has no hardware RTC so reliable NTP is critical.
ntp:
  enabled: true
  ntp_client: chrony
  servers: []
  pools:
    - 0.pool.ntp.org
    - 1.pool.ntp.org
    - 2.pool.ntp.org
    - 3.pool.ntp.org

# --- First-boot commands ------------------------------------------------------
runcmd:
  # Switch sudo-rs to traditional sudo (Ubuntu 25.10+ compatibility with Ansible)
  - |
    if [ -x /usr/bin/sudo.ws ]; then
      update-alternatives --set sudo /usr/bin/sudo.ws 2>/dev/null || true
    fi
  # Allow chrony to step clock at any time (no hardware RTC)
  - sed -i 's/^makestep.*/makestep 1 -1/' /etc/chrony/chrony.conf && systemctl restart chrony
  # Disable unattended-upgrades (Ansible manages updates)
  - systemctl disable --now unattended-upgrades.service || true
  - systemctl disable --now apt-daily.timer || true
  - systemctl disable --now apt-daily-upgrade.timer || true
  # Signal cloud-init completed (useful for monitoring)
  - touch /etc/cloud/cloud-init.done
