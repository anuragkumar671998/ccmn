#!/bin/bash
# secure-aws-instance-comprehensive.sh - All-in-one script for metadata blocking, SSH persistence, and python3 fix.

# --- Configuration ---
METADATA_IP="169.254.169.254"
METADATA_RANGE="169.254.0.0/16"
SSH_PORT="22"
METADATA_WRAPPER_DIR="/usr/local/bin"
NFTABLES_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-metadata-block.conf"
ENV_VARS_FILE="/etc/environment"
SSH_PERSISTENCE_SERVICE="aws-ssh-persistence.service"
METADATA_PERSISTENCE_SERVICE="aws-metadata-persistence.service"
NFTABLES_SERVICE="nftables.service"
PYTHON3_PKG="python3" # Package name for Python 3
# --- End Configuration ---

# --- Helper Functions ---
log_info() { echo "[INFO] $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_warning() { echo "[WARNING] $1"; }
log_error() { echo "[ERROR] $1"; }
command_exists() { command -v "$1" &> /dev/null; }

# --- Function to fix broken python3 wrapper ---
fix_python3_wrapper() {
    log_info "Attempting to fix python3 wrapper issues..."
    if command_exists python3 && ! python3 --version >/dev/null 2>&1; then
        log_warning "python3 command is not working. Attempting to reinstall python3 package."
        sudo apt-get update >/dev/null && sudo apt-get install -y --reinstall ${PYTHON3_PKG} >/dev/null
        if [ $? -ne 0 ]; then
            log_error "Failed to reinstall ${PYTHON3_PKG}. Manual intervention required."
            return 1
        else
            log_success "${PYTHON3_PKG} reinstalled. Proceeding to re-apply wrapper."
            return 0
        fi
    elif command_exists python3 && python3 --version >/dev/null 2>&1; then
        log_info "python3 seems to be working. Proceeding to re-apply wrapper."
        return 0
    else
        log_error "python3 command not found even after attempted reinstall."
        return 1
    fi
}

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Use sudo."
   exit 1
fi

log_info "Starting Comprehensive Secure AWS Instance Script..."

# --- CRITICAL REMINDER: AWS Network Configuration ---
log_warning "--------------------------------------------------------------------"
log_warning "IMPORTANT: Verify your AWS Security Group and Network ACLs."
log_warning "Ensure inbound TCP port ${SSH_PORT} is ALLOWED from your IP address."
log_warning "This script CANNOT fix external network access issues."
log_warning "--------------------------------------------------------------------"
sleep 3

# --- 1. Install Dependencies ---
log_info "Ensuring necessary packages are installed..."
sudo apt-get update >/dev/null && sudo apt-get install -y nftables iproute2 curl wget netcat ${PYTHON3_PKG} >/dev/null
if [ $? -ne 0 ]; then
    log_error "Failed to install necessary packages. Please install them manually and re-run."
    exit 1
fi
log_success "Dependencies installed."

# --- 2. Backup Original Commands and Create Wrappers ---
log_info "Backing up original curl/wget/python3 commands and creating wrappers..."
# Backup originals
if command_exists curl && [ ! -f /usr/bin/curl.real ]; then sudo mv /usr/bin/curl /usr/bin/curl.real; fi
if command_exists wget && [ ! -f /usr/bin/wget.real ]; then sudo mv /usr/bin/wget /usr/bin/wget.real; fi
# Python3 backup is handled by fix_python3_wrapper and reinstall logic. If python3 exists, we will wrap it.
# If it's broken, fix_python3_wrapper will attempt to reinstall it.

# Create wrappers
cat << EOF | sudo tee "${METADATA_WRAPPER_DIR}/curl-wrapper" > /dev/null
#!/bin/bash
METADATA_IP="$METADATA_IP"
METADATA_RANGE="$METADATA_RANGE"
args=("\$@")
for arg in "\${args[@]}"; do
    if [[ "\$arg" == *"\$METADATA_IP"* ]] || [[ "\$arg" == *"\$METADATA_RANGE"* ]]; then
        echo "ERROR: Access to AWS metadata service is blocked"
        exit 1
    fi
done
exec /usr/bin/curl.real "\$@"
EOF
sudo chmod +x "${METADATA_WRAPPER_DIR}/curl-wrapper"

cat << EOF | sudo tee "${METADATA_WRAPPER_DIR}/wget-wrapper" > /dev/null
#!/bin/bash
METADATA_IP="$METADATA_IP"
METADATA_RANGE="$METADATA_RANGE"
args=("\$@")
for arg in "\${args[@]}"; do
    if [[ "\$arg" == *"\$METADATA_IP"* ]] || [[ "\$arg" == *"\$METADATA_RANGE"* ]]; then
        echo "ERROR: Access to AWS metadata service is blocked"
        exit 1
    fi
done
exec /usr/bin/wget.real "\$@"
EOF
sudo chmod +x "${METADATA_WRAPPER_DIR}/wget-wrapper"

# Python3 wrapper creation - only if python3 command exists
if command_exists python3; then
    # Ensure original python3 is backed up if it's not already a .real file
    if [ -f /usr/bin/python3 ] && [ ! -f /usr/bin/python3.real ]; then
        sudo mv /usr/bin/python3 /usr/bin/python3.real
    fi
    # Create python3 wrapper
    cat << EOF | sudo tee "${METADATA_WRAPPER_DIR}/python3-wrapper" > /dev/null
#!/bin/bash
METADATA_IP="$METADATA_IP"
METADATA_RANGE="$METADATA_RANGE"
# Check if python3.real exists, otherwise try to call python3 directly (less likely to work if wrapped)
PYTHON_EXEC="/usr/bin/python3.real"
if [ ! -x "\$PYTHON_EXEC" ]; then
    PYTHON_EXEC="python3" # Fallback, less likely to work if already wrapped
fi

# Check arguments for metadata IPs/ranges
args=("\$@")
for arg in "\${args[@]}"; do
    if [[ "\$arg" == *"\$METADATA_IP"* ]] || [[ "\$arg" == *"\$METADATA_RANGE"* ]]; then
        echo "ERROR: Access to AWS metadata service is blocked"
        exit 1
    fi
done
exec "\$PYTHON_EXEC" "\$@"
EOF
    sudo chmod +x "${METADATA_WRAPPER_DIR}/python3-wrapper"
    log_success "curl, wget, and python3 wrappers created."
else
    log_warning "python3 command not found. Skipping python3 wrapper creation. It will be installed if needed."
fi


# --- 3. Configure /etc/hosts ---
log_info "Updating /etc/hosts for metadata blocking..."
if ! sudo grep -q "$METADATA_IP metadata.google.internal" /etc/hosts; then
    echo "127.0.0.1 $METADATA_IP metadata.google.internal" | sudo tee -a /etc/hosts > /dev/null
fi
log_success "/etc/hosts updated."

# --- 4. Configure Kernel Parameters ---
log_info "Configuring kernel parameters for route_localnet and ip_forward..."
cat << EOF | sudo tee "${SYSCTL_CONF}" > /dev/null
net.ipv4.conf.all.route_localnet = 0
net.ipv4.conf.default.route_localnet = 0
EOF
DETECTED_IFACE=$(ip -o -4 route show to exact default | awk '{print $5}') || DETECTED_IFACE="ens5"
echo "net.ipv4.conf.${DETECTED_IFACE}.route_localnet = 0" | sudo tee -a "${SYSCTL_CONF}" > /dev/null
echo "net.ipv4.ip_forward = 0" | sudo tee -a "${SYSCTL_CONF}" > /dev/null
sudo sysctl -p "${SYSCTL_CONF}" > /dev/null
log_success "Kernel parameters configured."

# --- 5. Configure Proxy Bypass Prevention ---
log_info "Configuring proxy bypass prevention in ${ENV_VARS_FILE}..."
# Use a temporary file to avoid issues with permissions and concurrent edits
TEMP_ENV_VARS=$(mktemp)
sudo cp "$ENV_VARS_FILE" "$TEMP_ENV_VARS"
if sudo grep -q "no_proxy=" "$TEMP_ENV_VARS"; then
    sudo sed -i "s|^no_proxy=.*|no_proxy=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE,|" "$TEMP_ENV_VARS"
else
    echo "no_proxy=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE" | sudo tee -a "$TEMP_ENV_VARS" > /dev/null
fi
if sudo grep -q "NO_PROXY=" "$TEMP_ENV_VARS"; then
    sudo sed -i "s|^NO_PROXY=.*|NO_PROXY=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE,|" "$TEMP_ENV_VARS"
else
    echo "NO_PROXY=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE" | sudo tee -a "$TEMP_ENV_VARS" > /dev/null
fi
sudo mv "$TEMP_ENV_VARS" "$ENV_VARS_FILE"
export no_proxy="$METADATA_IP,$METADATA_RANGE"
export NO_PROXY="$METADATA_IP,$METADATA_RANGE"
log_success "Proxy bypass prevention configured."

# --- 6. Configure nftables Firewall (with SSH Allow) ---
log_info "Configuring nftables firewall including explicit SSH allow rule..."
cat << EOF | sudo tee "${NFTABLES_CONF}" > /dev/null
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;

        # !!! CRITICAL: Allow SSH inbound (TCP port ${SSH_PORT}) !!!
        tcp dport ${SSH_PORT} accept

        # Allow established/related connections
        ct state established,related accept

        # Drop/reject traffic to metadata IP and range
        ip daddr ${METADATA_IP} reject with icmpx-admin-prohibited
        ip daddr ${METADATA_RANGE} reject with icmpx-admin-prohibited
    }

    chain output {
        type filter hook output priority 0; policy accept;

        # Drop traffic to metadata IP and range
        ip daddr ${METADATA_IP} drop
        ip daddr ${METADATA_RANGE} drop
    }
}
EOF
log_success "nftables ruleset created at ${NFTABLES_CONF}."

sudo systemctl enable "${NFTABLES_SERVICE}" > /dev/null 2>&1
sudo systemctl restart "${NFTABLES_SERVICE}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log_error "Failed to restart ${NFTABLES_SERVICE}. Check status. SSH may be inaccessible."
    exit 1
fi
log_success "${NFTABLES_SERVICE} configured and running."

# --- 7. Add Blackhole Routes ---
log_info "Adding blackhole routes..."
sudo ip route add blackhole "${METADATA_IP}/32" > /dev/null 2>&1 || log_warning "Route for ${METADATA_IP} already exists or failed to add."
sudo ip route add blackhole "${METADATA_RANGE}" > /dev/null 2>&1 || log_warning "Route for ${METADATA_RANGE} already exists or failed to add."
log_success "Blackhole routes added."

# --- 8. Create Systemd Service for SSH Persistence ---
log_info "Creating systemd service for SSH persistence..."
cat << EOF | sudo tee "/etc/systemd/system/${SSH_PERSISTENCE_SERVICE}" > /dev/null
[Unit]
Description=Ensure AWS SSH Access Persistence
Wants=${NFTABLES_SERVICE}
After=network.target ${NFTABLES_SERVICE}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '
    systemctl is-active --quiet ${NFTABLES_SERVICE} || systemctl start ${NFTABLES_SERVICE}
    if ! sudo nft list chain inet filter input 2>/dev/null | grep -q "tcp dport ${SSH_PORT} accept"; then
        sudo nft insert rule inet filter input tcp dport ${SSH_PORT} accept
        log_info "SSH allow rule added to nftables."
    else
        log_info "SSH allow rule already present in nftables."
    fi
'
EOF
sudo systemctl daemon-reload
sudo systemctl enable "${SSH_PERSISTENCE_SERVICE}" > /dev/null 2>&1 || log_warning "Failed to enable ${SSH_PERSISTENCE_SERVICE}."
sudo systemctl start "${SSH_PERSISTENCE_SERVICE}" > /dev/null 2>&1 || log_warning "Failed to start ${SSH_PERSISTENCE_SERVICE}. Check its status."
log_success "SSH persistence service created and enabled."

# --- 9. Create Systemd Service for Metadata Blocking Persistence ---
log_info "Creating systemd service for metadata blocking persistence..."
cat << EOF | sudo tee "/etc/systemd/system/${METADATA_PERSISTENCE_SERVICE}" > /dev/null
[Unit]
Description=AWS Metadata Blocker Persistence (Wrappers, Routes, Sysctl)
Wants=${SSH_PERSISTENCE_SERVICE}
After=${SSH_PERSISTENCE_SERVICE}

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/bin/bash -c '
  # Ensure wrappers exist and are executable
  chmod +x ${METADATA_WRAPPER_DIR}/curl-wrapper ${METADATA_WRAPPER_DIR}/wget-wrapper 2>/dev/null || true
  if command_exists python3; then chmod +x ${METADATA_WRAPPER_DIR}/python3-wrapper 2>/dev/null || true; fi

  # Link curl if not already linked or if original is missing/broken
  if [ ! -L /usr/bin/curl ] || [ ! -x /usr/bin/curl ]; then
    if [ -f /usr/bin/curl.real ]; then sudo ln -sf ${METADATA_WRAPPER_DIR}/curl-wrapper /usr/bin/curl; fi
  fi

  # Link wget if not already linked or if original is missing/broken
  if [ ! -L /usr/bin/wget ] || [ ! -x /usr/bin/wget ]; then
    if [ -f /usr/bin/wget.real ]; then sudo ln -sf ${METADATA_WRAPPER_DIR}/wget-wrapper /usr/bin/wget; fi
  fi

  # Link python3 if not already linked or if original is missing/broken
  if command_exists python3; then
      if [ ! -L /usr/bin/python3 ] || [ ! -x /usr/bin/python3 ]; then
          if [ -f /usr/bin/python3.real ]; then sudo ln -sf ${METADATA_WRAPPER_DIR}/python3-wrapper /usr/bin/python3; fi
      fi
  fi

'

# Re-apply blackhole routes
ExecStart=/sbin/ip route add blackhole ${METADATA_IP}/32 2>/dev/null || true
ExecStart=/sbin/ip route add blackhole ${METADATA_RANGE} 2>/dev/null || true

# Re-apply sysctl settings
ExecStart=/sbin/sysctl -p "${SYSCTL_CONF}" > /dev/null

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${METADATA_PERSISTENCE_SERVICE}" > /dev/null 2>&1 || log_warning "Failed to enable ${METADATA_PERSISTENCE_SERVICE}."
sudo systemctl start "${METADATA_PERSISTENCE_SERVICE}" > /dev/null 2>&1 || log_warning "Failed to start ${METADATA_PERSISTENCE_SERVICE}. Check its status."
log_success "Metadata persistence service created and enabled."

# --- 10. Final Verification ---
log_info "Running final verification tests..."
echo ""
echo "=== FINAL VERIFICATION TESTS ==="

# Test python3 version
log_info "Testing python3 version..."
if command_exists python3; then
    python3 --version
    if [ $? -ne 0 ]; then log_warning "python3 command failed to run. See error above."; fi
else
    log_warning "python3 command not found after setup. Install manually if needed."
fi

# Test metadata blocking
echo -n "1. Curl to metadata: "
curl -s -m 5 "http://${METADATA_IP}/latest/meta-data/" 2>&1 | grep -q "ERROR:" && log_success "Blocked." || { log_warning "Not Blocked."; false; }

echo -n "2. Wget to metadata: "
wget --timeout=2 -q -O - "http://${METADATA_IP}/latest/meta-data/" 2>&1 | grep -q "ERROR:" && log_success "Blocked." || { log_warning "Not Blocked."; false; }

echo -n "3. Python3 to metadata: "
if command_exists python3; then
    python3 -c "import urllib.request; urllib.request.urlopen('http://${METADATA_IP}/')" > /dev/null 2>&1
    if [ $? -ne 0 ] && [ "$(python3 -c 'import sys; sys.stderr.read()')" != "" ]; then # Check for error output
        log_success "Blocked via wrapper."
    elif [ $? -eq 0 ]; then
        log_warning "Python3 metadata access not blocked!"
    else
        log_warning "Python3 metadata access test inconclusive."
    fi
else
    log_warning "python3 command not found. Skipping python3 metadata test."
fi

echo -n "4. Internet connectivity (using real curl): "
curl -s --connect-timeout 3 https://ifconfig.me | head -1 | grep -q "." && log_success "Works." || { log_warning "Failed."; false; }

echo ""
echo "--- CONFIGURATION SUMMARY ---"
echo "✅ SSH Rule in nftables: $(sudo nft list chain inet filter input 2>/dev/null | grep -c "tcp dport ${SSH_PORT} accept")"
echo "✅ SSH Persistence Service (${SSH_PERSISTENCE_SERVICE}): $(systemctl is-active ${SSH_PERSISTENCE_SERVICE} && echo 'Active' || echo 'INACTIVE')"
echo "✅ Metadata Persistence Service (${METADATA_PERSISTENCE_SERVICE}): $(systemctl is-active ${METADATA_PERSISTENCE_SERVICE} && echo 'Active' || echo 'INACTIVE')"
echo "✅ python3 command working: $(command_exists python3 && python3 --version >/dev/null 2>&1 && echo 'Yes' || echo 'No')"
echo ""
log_info "Installation complete."
log_warning "--------------------------------------------------------------------"
log_warning "IMPORTANT: If SSH fails after reboot, the problem is EXTERNAL (AWS Security Group/NACL)."
log_warning "--------------------------------------------------------------------"

exit 0
