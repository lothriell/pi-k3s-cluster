# =============================================================================
# Cloud-init network configuration for Pi K3s cluster nodes
# =============================================================================
# Uses DHCP by default. Static IPs are assigned via UniFi Gateway
# DHCP reservations (by MAC address), not here.
#
# If you prefer static IPs directly on the node, uncomment the static
# section below and comment out the DHCP section.
# =============================================================================

network:
  version: 2
  ethernets:
    eth0:
      # --- DHCP (default) ---
      # IPs assigned by UniFi Gateway DHCP reservations
      dhcp4: true

      # --- Static IP (alternative) ---
      # Uncomment below and replace __IP_ADDRESS__ and __GATEWAY__
      # dhcp4: false
      # addresses:
      #   - __IP_ADDRESS__/24
      # routes:
      #   - to: default
      #     via: __GATEWAY__
      # nameservers:
      #   addresses:
      #     - 1.1.1.1
      #     - 8.8.8.8
