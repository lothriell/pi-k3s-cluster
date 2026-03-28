#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Flash Ubuntu Server to CM5 eMMC and inject cloud-init config
# =============================================================================
#
# Usage:
#   ./scripts/flash-node.sh <hostname> [image-path]
#
# Examples:
#   ./scripts/flash-node.sh rpi-k3s-1
#   ./scripts/flash-node.sh rpi-k3s-2 ~/Downloads/ubuntu-24.04-preinstalled-server-arm64+raspi.img.xz
#
# Prerequisites:
#   1. Install rpiboot: brew install --cask raspberry-pi-imager
#      Or build from source: https://github.com/raspberrypi/usbboot
#   2. Set nRPIBOOT jumper on CM5 carrier board
#   3. Connect CM5 to Mac via USB
#   4. Have Ubuntu Server ARM64 image downloaded
#
# What this script does:
#   1. Runs rpiboot to expose CM5 eMMC as USB mass storage
#   2. Detects the eMMC device
#   3. Flashes the Ubuntu image to eMMC
#   4. Mounts the boot partition
#   5. Writes cloud-init files (user-data, network-config, meta-data)
#      with the correct hostname substituted
#   6. Unmounts everything
#
# After running:
#   - Remove the nRPIBOOT jumper
#   - Power on the CM5
#   - Wait ~2-3 minutes for cloud-init
#   - Ansible can connect: ansible <hostname> -m ping
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLOUD_INIT_DIR="${PROJECT_DIR}/cloud-init"
GROUP_VARS="${PROJECT_DIR}/ansible/inventory/group_vars/all.yml"

# --- Load config from group_vars/all.yml ------------------------------------

if [[ ! -f "$GROUP_VARS" ]]; then
    echo "  ERROR: ${GROUP_VARS} not found."
    echo "  Copy from all.yml.example and fill in your values:"
    echo "    cp ansible/inventory/group_vars/all.yml.example ansible/inventory/group_vars/all.yml"
    exit 1
fi

# Parse YAML values (simple key: value extraction)
PERSONAL_USER=$(grep '^personal_user:' "$GROUP_VARS" | awk '{print $2}' | tr -d '"')
SSH_PUBKEY=$(grep '^ssh_pubkey:' "$GROUP_VARS" | sed 's/^ssh_pubkey: *//' | tr -d '"')

if [[ -z "$PERSONAL_USER" || -z "$SSH_PUBKEY" ]]; then
    echo "  ERROR: personal_user or ssh_pubkey not set in ${GROUP_VARS}"
    exit 1
fi

echo "  Config: user=${PERSONAL_USER}, key=${SSH_PUBKEY:0:30}..."

# --- Arguments ---------------------------------------------------------------

HOSTNAME="${1:-}"
IMAGE_PATH="${2:-}"

if [[ -z "$HOSTNAME" ]]; then
    echo ""
    echo "  Usage: $0 <hostname> [image-path]"
    echo ""
    echo "  Available hostnames:"
    echo "    rpi-k3s-1  (server / control plane)"
    echo "    rpi-k3s-2  (agent / worker)"
    echo "    rpi-k3s-3  (agent / worker)"
    echo "    rpi-k3s-4  (agent / worker)"
    echo ""
    echo "  Example:"
    echo "    $0 rpi-k3s-1 ~/Downloads/ubuntu-server.img.xz"
    echo ""
    exit 1
fi

# --- Validate hostname -------------------------------------------------------

VALID_HOSTNAMES=("rpi-k3s-1" "rpi-k3s-2" "rpi-k3s-3" "rpi-k3s-4")
if [[ ! " ${VALID_HOSTNAMES[*]} " =~ " ${HOSTNAME} " ]]; then
    echo "ERROR: Invalid hostname '${HOSTNAME}'"
    echo "Valid hostnames: ${VALID_HOSTNAMES[*]}"
    exit 1
fi

echo ""
echo "  =================================================="
echo "    CM5 eMMC Flash: ${HOSTNAME}"
echo "  =================================================="
echo ""

# --- Step 1: Expose eMMC via rpiboot -----------------------------------------

echo "--- Step 1: Expose CM5 eMMC via USB ---"
echo ""
echo "  Make sure:"
echo "    1. nRPIBOOT jumper is SET on the carrier board"
echo "    2. CM5 is connected to your Mac via USB"
echo "    3. CM5 is powered on"
echo ""
read -rp "  Press Enter when ready (or Ctrl+C to cancel)..."
echo ""

RPIBOOT_DIR="${RPIBOOT_DIR:-${HOME}/Git/usbboot}"
if [[ -x "${RPIBOOT_DIR}/rpiboot" ]]; then
    echo "  Running rpiboot from ${RPIBOOT_DIR}..."
    (cd "$RPIBOOT_DIR" && sudo ./rpiboot -d mass-storage-gadget64)
elif command -v rpiboot &>/dev/null; then
    echo "  Running rpiboot..."
    sudo rpiboot -d mass-storage-gadget64
elif [[ -x /usr/local/bin/rpiboot ]]; then
    echo "  Running rpiboot..."
    sudo /usr/local/bin/rpiboot -d mass-storage-gadget64
else
    echo "  ERROR: rpiboot not found."
    echo "  Install it: https://github.com/raspberrypi/usbboot"
    echo "  Set RPIBOOT_DIR env var if installed elsewhere."
    exit 1
fi

echo ""
echo "  Waiting for eMMC to appear as disk..."
sleep 5

# --- Step 2: Detect eMMC device ----------------------------------------------

echo "--- Step 2: Detect eMMC device ---"
echo ""

# On macOS, the CM5 eMMC typically appears as /dev/diskN
# Look for a ~32GB disk that just appeared
EMMC_DISK=""
for disk in /dev/disk2 /dev/disk3 /dev/disk4 /dev/disk5 /dev/disk6 /dev/disk7 /dev/disk8; do
    if diskutil info "$disk" &>/dev/null; then
        SIZE=$(diskutil info "$disk" | grep "Disk Size" | head -1)
        if echo "$SIZE" | grep -qE "2[89]\.|3[0-2]\."; then
            EMMC_DISK="$disk"
            echo "  Found eMMC: $disk"
            echo "  $SIZE"
            break
        fi
    fi
done

if [[ -z "$EMMC_DISK" ]]; then
    echo "  Could not auto-detect eMMC. Available disks:"
    diskutil list | grep -E "^/dev/disk"
    echo ""
    read -rp "  Enter disk path (e.g., /dev/disk2): " EMMC_DISK
fi

echo ""
echo "  WARNING: All data on ${EMMC_DISK} will be erased!"
echo ""
read -rp "  Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "  Aborted."
    exit 0
fi

# --- Step 3: Flash image -----------------------------------------------------

echo ""
echo "--- Step 3: Flash Ubuntu Server image ---"
echo ""

if [[ -z "$IMAGE_PATH" ]]; then
    echo "  No image path provided."
    echo "  You can:"
    echo "    a) Provide the image path as the second argument"
    echo "    b) Use Raspberry Pi Imager to flash manually, then re-run with --cloud-init-only"
    echo ""
    read -rp "  Enter image path (or 'skip' to only inject cloud-init): " IMAGE_PATH
fi

if [[ "$IMAGE_PATH" != "skip" && -n "$IMAGE_PATH" ]]; then
    echo "  Unmounting ${EMMC_DISK}..."
    diskutil unmountDisk "$EMMC_DISK" || true

    echo "  Flashing ${IMAGE_PATH} to ${EMMC_DISK}..."
    echo "  (This takes 5-10 minutes for a 32GB eMMC)"

    RAW_DISK="${EMMC_DISK/disk/rdisk}"

    if [[ "$IMAGE_PATH" == *.xz ]]; then
        xz -dc "$IMAGE_PATH" | sudo dd of="$RAW_DISK" bs=4M status=progress
    elif [[ "$IMAGE_PATH" == *.gz ]]; then
        gzip -dc "$IMAGE_PATH" | sudo dd of="$RAW_DISK" bs=4M status=progress
    else
        sudo dd if="$IMAGE_PATH" of="$RAW_DISK" bs=4M status=progress
    fi

    sync
    echo "  Flash complete."
    echo ""

    # Wait for macOS to detect partitions
    sleep 3
    diskutil mountDisk "$EMMC_DISK" 2>/dev/null || true
    sleep 2
fi

# --- Step 4: Inject cloud-init ------------------------------------------------

echo "--- Step 4: Inject cloud-init configuration ---"
echo ""

# Find the boot partition mount point (FAT32, labeled "system-boot" on Ubuntu)
BOOT_MOUNT=""
for mount in /Volumes/system-boot /Volumes/boot /Volumes/bootfs; do
    if [[ -d "$mount" ]]; then
        BOOT_MOUNT="$mount"
        break
    fi
done

if [[ -z "$BOOT_MOUNT" ]]; then
    echo "  Could not find boot partition. Available volumes:"
    ls /Volumes/
    echo ""
    read -rp "  Enter boot partition mount path: " BOOT_MOUNT
fi

echo "  Boot partition: ${BOOT_MOUNT}"
echo "  Writing cloud-init files for ${HOSTNAME}..."

# Generate user-data with all variables substituted
sed -e "s/__HOSTNAME__/${HOSTNAME}/g" \
    -e "s/__USERNAME__/${PERSONAL_USER}/g" \
    -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|g" \
    "${CLOUD_INIT_DIR}/user-data.tpl" > "${BOOT_MOUNT}/user-data"

# Copy network-config (DHCP, no per-node changes needed)
cp "${CLOUD_INIT_DIR}/network-config.tpl" "${BOOT_MOUNT}/network-config"

# Generate meta-data with hostname
sed "s/__HOSTNAME__/${HOSTNAME}/g" "${CLOUD_INIT_DIR}/meta-data.tpl" > "${BOOT_MOUNT}/meta-data"

echo "  Written:"
echo "    ${BOOT_MOUNT}/user-data"
echo "    ${BOOT_MOUNT}/network-config"
echo "    ${BOOT_MOUNT}/meta-data"
echo ""

# --- Step 5: Unmount ----------------------------------------------------------

echo "--- Step 5: Unmount ---"
diskutil unmountDisk "$EMMC_DISK"

echo ""
echo "  =================================================="
echo "    Flash complete for ${HOSTNAME}!"
echo "  =================================================="
echo ""
echo "  Next steps:"
echo "    1. Remove the nRPIBOOT jumper"
echo "    2. Power on the CM5"
echo "    3. Wait ~2-3 minutes for cloud-init to finish"
echo "    4. Set DHCP reservation in UniFi for this node's MAC"
echo "    5. Test: ssh -i ~/.ssh/id_ed25519 ansible@<ip> 'hostname'"
echo "    6. Test: ansible ${HOSTNAME} -m ping"
echo ""
