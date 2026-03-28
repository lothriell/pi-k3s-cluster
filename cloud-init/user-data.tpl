#cloud-config
# =============================================================================
# Cloud-init user-data template for Pi K3s cluster nodes
# =============================================================================
# This file is processed by cloud-init on FIRST BOOT ONLY.
# Place it on the boot partition as 'user-data' (no extension).
#
# Variables replaced by flash-node.sh:
#   __HOSTNAME__      - e.g., rpi-k3s-1, rpi-k3s-2, etc.
#   __USERNAME__      - personal user account name
#   __SSH_PUBKEY__    - SSH public key for both users
#   __PASSWORD_HASH__ - hashed password for personal user
#
# flash-node.sh also copies dotfiles to /boot/firmware/dotfiles/
# which runcmd installs during first boot.
# =============================================================================

# --- Identity ----------------------------------------------------------------
hostname: __HOSTNAME__
manage_etc_hosts: true

# --- Timezone / Locale -------------------------------------------------------
timezone: UTC
locale: en_US.UTF-8

# --- Users --------------------------------------------------------------------
users:
  - name: __USERNAME__
    gecos: Personal Account
    groups: adm, sudo, systemd-journal
    shell: /bin/zsh
    sudo: "ALL=(ALL:ALL) ALL"
    lock_passwd: false
    passwd: "__PASSWORD_HASH__"
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
package_update: true
package_upgrade: false
packages:
  - python3
  - curl
  - wget
  - zsh
  - git
  - unzip
  - fontconfig

# --- NTP ----------------------------------------------------------------------
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
  # Switch sudo-rs to traditional sudo (Ubuntu 25.10+ only, harmless on 24.04)
  - |
    if [ -x /usr/bin/sudo.ws ]; then
      update-alternatives --set sudo /usr/bin/sudo.ws 2>/dev/null || true
    fi
  # Disable eMMC Command Queue Engine to prevent freeze after ~3.5 days
  - |
    if ! grep -q 'sdhci.cqe=0' /boot/firmware/cmdline.txt 2>/dev/null; then
      sed -i 's/$/ sdhci.cqe=0/' /boot/firmware/cmdline.txt
    fi
  # Allow chrony to step clock at any time (no hardware RTC)
  - sed -i 's/^makestep.*/makestep 1 -1/' /etc/chrony/chrony.conf && systemctl restart chrony
  # Disable unattended-upgrades (Ansible manages updates)
  - systemctl disable --now unattended-upgrades.service || true
  - systemctl disable --now apt-daily.timer || true
  - systemctl disable --now apt-daily-upgrade.timer || true
  # --- Install eza ---
  - |
    if ! command -v eza &>/dev/null; then
      wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
      echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | tee /etc/apt/sources.list.d/gierens.list
      apt update && apt install -y eza
    fi
  # --- Install oh-my-posh ---
  - curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin
  # --- Setup shell for personal user ---
  - |
    USERNAME="__USERNAME__"
    HOME_DIR="/home/${USERNAME}"
    # Install Oh My Zsh
    su - ${USERNAME} -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    # Install zsh-autosuggestions plugin
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git ${HOME_DIR}/.oh-my-zsh/custom/plugins/zsh-autosuggestions
    # Copy dotfiles from boot partition
    if [ -d /boot/firmware/dotfiles ]; then
      cp /boot/firmware/dotfiles/zshrc ${HOME_DIR}/.zshrc
      mkdir -p ${HOME_DIR}/.config/oh-my-posh/themes
      cp /boot/firmware/dotfiles/atomic.omp.json ${HOME_DIR}/.config/oh-my-posh/themes/
      chown -R ${USERNAME}:${USERNAME} ${HOME_DIR}/.oh-my-zsh ${HOME_DIR}/.zshrc ${HOME_DIR}/.config
    fi
  # --- Setup shell for root ---
  - |
    USERNAME="__USERNAME__"
    HOME_DIR="/home/${USERNAME}"
    chsh -s /bin/zsh root
    su - root -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git /root/.oh-my-zsh/custom/plugins/zsh-autosuggestions
    cp ${HOME_DIR}/.zshrc /root/.zshrc
    mkdir -p /root/.config/oh-my-posh/themes
    cp ${HOME_DIR}/.config/oh-my-posh/themes/atomic.omp.json /root/.config/oh-my-posh/themes/
  # Signal cloud-init completed and reboot to apply kernel params (sdhci.cqe=0)
  - touch /etc/cloud/cloud-init.done
  - reboot
