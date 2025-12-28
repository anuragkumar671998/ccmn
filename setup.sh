#!/bin/bash
# block-aws-metadata-secure-ssh-fix.sh - Robust script to block metadata, ensure SSH is allowed, and persist across reboots.

# --- Configuration ---
METADATA_IP="169.254.169.254"
METADATA_RANGE="169.254.0.0/16"
SSH_PORT="22"
METADATA_WRAPPER_DIR="/usr/local/bin"
NFTABLES_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-metadata-block.conf"
ENV_VARS_FILE="/etc/environment"
METADATA_PERSISTENCE_SERVICE="aws-metadata-ssh-protection.service"
NFTABLES_SERVICE="nftables.service"
# --- End Configuration ---

# --- Helper Functions ---
log_info() { echo "[INFO] $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_warning() { echo "[WARNING] $1"; }
log_error() { echo "[ERROR] $1"; }
command_exists() { command -v "$1" &> /dev/null; }

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Use sudo."
   exit 1
fi

log_info "Starting AWS Metadata & SSH Protection Script..."

# --- CRITICAL: AWS Security Group Check Reminder ---
log_warning "--------------------------------------------------------------------"
log_warning "IMPORTANT: Ensure your AWS Security Group allows inbound SSH (TCP port ${SSH_PORT}) from your IP address."
log_warning "This script cannot fix external network configurations."
log_warning "--------------------------------------------------------------------"
sleep 3 # Give user time to read

# --- 1. Install Dependencies ---
log_info "Ensuring necessary packages are installed (nftables, iproute2, curl, wget, netcat)..."
apt-get update >/dev/null && apt-get install -y nftables iproute2 curl wget netcat >/dev/null
if [ $? -ne 0 ]; then
    log_error "Failed to install necessary packages. Please install them manually and re-run the script."
    exit 1
fi
log_success "Dependencies installed."

# --- 2. Backup Original Commands and Create Wrappers ---
log_info "Backing up original curl and wget commands if they are not already backed up..."
if command_exists curl && [ ! -f /usr/bin/curl.real ]; then
    mv /usr/bin/curl /usr/bin/curl.real 2>/dev/null
    log_info "Original curl moved to /usr/bin/curl.real"
fi
if command_exists wget && [ ! -f /usr/bin/wget.real ]; then
    mv /usr/bin/wget /usr/bin/wget.real 2>/dev/null
    log_info "Original wget moved to /usr/bin/wget.real"
fi
log_success "Original commands backed up."

log_info "Creating application wrappers for curl and wget..."
cat << EOF > "${METADATA_WRAPPER_DIR}/curl-wrapper"
#!/bin/bash
# Wrapper to block AWS metadata access by checking arguments
METADATA_IP="$METADATA_IP"
METADATA_RANGE="$METADATA_RANGE"

# Check if any argument contains metadata IP or domain
args=("$@")
for arg in "\${args[@]}"; do
    if [[ "\$arg" == *"\$METADATA_IP"* ]] || [[ "\$arg" == *"\$METADATA_RANGE"* ]]; then
        echo "ERROR: Access to AWS metadata service is blocked"
        exit 1
    fi
done
# Call the original command
/usr/bin/curl.real "\$@"
EOF
chmod +x "${METADATA_WRAPPER_DIR}/curl-wrapper"

cat << EOF > "${METADATA_WRAPPER_DIR}/wget-wrapper"
#!/bin/bash
# Wrapper to block AWS metadata access by checking arguments
METADATA_IP="$METADATA_IP"
METADATA_RANGE="$METADATA_RANGE"

# Check if any argument contains metadata IP or domain
args=("$@")
for arg in "\${args[@]}"; do
    if [[ "\$arg" == *"\$METADATA_IP"* ]] || [[ "\$arg" == *"\$METADATA_RANGE"* ]]; then
        echo "ERROR: Access to AWS metadata service is blocked"
        exit 1
    fi
done
# Call the original command
/usr/bin/wget.real "\$@"
EOF
chmod +x "${METADATA_WRAPPER_DIR}/wget-wrapper"
log_success "curl and wget wrappers installed."

# --- 3. Configure /etc/hosts ---
log_info "Updating /etc/hosts to block metadata DNS resolution..."
if ! grep -q "$METADATA_IP metadata.google.internal" /etc/hosts; then
    echo "127.0.0.1 $METADATA_IP metadata.google.internal" >> /etc/hosts
    log_success "/etc/hosts updated."
else
    log_warning "/etc/hosts already contains metadata blocking entry. Ensuring it's correct."
    sed -i "s|^127.0.0.1.*metadata.google.internal|127.0.0.1 $METADATA_IP metadata.google.internal|" /etc/hosts
fi

# --- 4. Configure Kernel Parameters ---
log_info "Configuring kernel parameters for route_localnet..."
cat << EOF > "$SYSCTL_CONF"
# Prevent routing to local meta-IPs
net.ipv4.conf.all.route_localnet = 0
net.ipv4.conf.default.route_localnet = 0
EOF
# Attempt to detect primary interface name, fallback to ens5
DETECTED_IFACE=$(ip -o -4 route show to exact default | awk '{print $5}')
if [ -z "$DETECTED_IFACE" ]; then
    DETECTED_IFACE="ens5" # Fallback
    log_warning "Could not auto-detect network interface, using fallback 'ens5'."
fi
echo "net.ipv4.conf.${DETECTED_IFACE}.route_localnet = 0" >> "$SYSCTL_CONF"
echo "net.ipv4.ip_forward = 0" >> "$SYSCTL_CONF"

sysctl -p "$SYSCTL_CONF" > /dev/null
log_success "Kernel parameters configured and applied."

# --- 5. Configure Proxy Bypass Prevention ---
log_info "Configuring proxy bypass prevention in ${ENV_VARS_FILE}..."
TEMP_ENV_VARS=$(mktemp)
cp "$ENV_VARS_FILE" "$TEMP_ENV_VARS"

# Ensure no_proxy is set correctly, prepending if not present
if grep -q "no_proxy=" "$TEMP_ENV_VARS"; then
    if ! grep -q "$METADATA_IP" "$TEMP_ENV_VARS"; then
        sed -i "s|^no_proxy=|no_proxy=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE,|" "$TEMP_ENV_VARS"
    fi
else
    echo "no_proxy=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE" >> "$TEMP_ENV_VARS"
fi

# Ensure NO_PROXY is set correctly, prepending if not present
if grep -q "NO_PROXY=" "$TEMP_ENV_VARS"; then
    if ! grep -q "$METADATA_IP" "$TEMP_ENV_VARS"; then
        sed -i "s|^NO_PROXY=|NO_PROXY=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE,|" "$TEMP_ENV_VARS"
    fi
else
    echo "NO_PROXY=localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE" >> "$TEMP_ENV_VARS"
fi

mv "$TEMP_ENV_VARS" "$ENV_VARS_FILE"
log_success "Proxy bypass prevention configured in ${ENV_VARS_FILE}."
export no_proxy="localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE"
export NO_PROXY="localhost,127.0.0.1,$METADATA_IP,$METADATA_RANGE"

# --- 6. Configure nftables Firewall (with SSH Allow) ---
log_info "Configuring nftables firewall including SSH allow rule..."
cat << EOF > "$NFTABLES_CONF"
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy accept; # Default to accept all incoming

        # !!! IMPORTANT: Allow SSH inbound (TCP port ${SSH_PORT}) !!!
        tcp dport ${SSH_PORT} accept

        # Allow established/related connections
        ct state established,related accept

        # Drop/reject traffic to metadata IP and range
        ip daddr ${METADATA_IP} reject with icmpx-admin-prohibited
        ip daddr ${METADATA_RANGE} reject with icmpx-admin-prohibited
    }

    chain output {
        type filter hook output priority 0; policy accept; # Default to accept all outgoing

        # Drop traffic to metadata IP and range
        ip daddr ${METADATA_IP} drop
        ip daddr ${METADATA_RANGE} drop
    }
}
EOF
log_success "nftables ruleset created at ${NFTABLES_CONF}."

# Ensure nftables service is enabled and running
if ! systemctl is-enabled "${NFTABLES_SERVICE}"; then
    systemctl enable "${NFTABLES_SERVICE}"
    log_info "${NFTABLES_SERVICE} enabled."
fi
systemctl restart "${NFTABLES_SERVICE}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log_error "Failed to restart ${NFTABLES_SERVICE}. Please check ${NFTABLES_CONF} and nftables service status."
    log_error "SSH may be inaccessible if nftables is broken. Manual intervention may be required."
    exit 1
fi
log_success "${NFTABLES_SERVICE} configured and running."

# --- 7. Add Blackhole Routes ---
log_info "Adding blackhole routes..."
ip route add blackhole "${METADATA_IP}/32" > /dev/null 2>&1 || log_warning "Route for ${METADATA_IP} already exists or failed to add."
ip route add blackhole "${METADATA_RANGE}" > /dev/null 2>&1 || log_warning "Route for ${METADATA_RANGE} already exists or failed to add."
log_success "Blackhole routes added."

# --- 8. Create Systemd Service for Persistence ---
log_info "Creating systemd service for persistence of wrappers, routes, sysctl, and nftables..."
cat << EOF > "/etc/systemd/system/${METADATA_PERSISTENCE_SERVICE}"
[Unit]
Description=AWS Metadata Blocker & SSH Persistence
Wants=${NFTABLES_SERVICE}
After=network.target ${NFTABLES_SERVICE}

[Service]
Type=oneshot
RemainAfterExit=yes

# Re-apply wrappers and ensure they are linked correctly
ExecStart=/bin/bash -c '
  # Ensure wrappers are executable and linked correctly
  chmod +x ${METADATA_WRAPPER_DIR}/curl-wrapper ${METADATA_WRAPPER_DIR}/wget-wrapper 2>/dev/null || true
  
  # Link curl if not already linked or if original is missing/broken
  if [ ! -L /usr/bin/curl ] || [ ! -x /usr/bin/curl ]; then
    if [ -f /usr/bin/curl.real ]; then
      ln -sf ${METADATA_WRAPPER_DIR}/curl-wrapper /usr/bin/curl
    elif command -v curl > /dev/null && [ ! -f /usr/bin/curl.real ]; then # If original curl exists but not .real
       mv /usr/bin/curl /usr/bin/curl.real 2>/dev/null
       ln -sf ${METADATA_WRAPPER_DIR}/curl-wrapper /usr/bin/curl
    fi
  fi

  # Link wget if not already linked or if original is missing/broken
  if [ ! -L /usr/bin/wget ] || [ ! -x /usr/bin/wget ]; then
    if [ -f /usr/bin/wget.real ]; then
      ln -sf ${METADATA_WRAPPER_DIR}/wget-wrapper /usr/bin/wget
    elif command -v wget > /dev/null && [ ! -f /usr/bin/wget.real ]; then # If original wget exists but not .real
       mv /usr/bin/wget /usr/bin/wget.real 2>/dev/null
       ln -sf ${METADATA_WRAPPER_DIR}/wget-wrapper /usr/bin/wget
    fi
  fi
'

# Re-apply blackhole routes
ExecStart=/sbin/ip route add blackhole ${METADATA_IP}/32 2>/dev/null || true
ExecStart=/sbin/ip route add blackhole ${METADATA_RANGE} 2>/dev/null || true

# Re-apply sysctl settings
ExecStart=/sbin/sysctl -p "${SYSCTL_CONF}" > /dev/null

# Ensure nftables service is active and rules are loaded (crucial for SSH allow rule)
ExecStart=/bin/systemctl is-active --quiet ${NFTABLES_SERVICE} || /bin/systemctl start ${NFTABLES_SERVICE}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${METADATA_PERSISTENCE_SERVICE}" > /dev/null 2>&1 || log_warning "Failed to enable ${METADATA_PERSISTENCE_SERVICE}."
systemctl restart "${METADATA_PERSISTENCE_SERVICE}" > /dev/null 2>&1 || log_warning "Failed to restart ${METADATA_PERSISTENCE_SERVICE}. Check its status."
log_success "Persistence service (${METADATA_PERSISTENCE_SERVICE}) created and enabled."

# --- 9. Final Verification ---
log_info "Running final verification tests..."
echo ""
echo "=== FINAL VERIFICATION TESTS ==="

echo -n "1. Curl to metadata: "
curl -s -m 5 "http://${METADATA_IP}/latest/meta-data/" 2>&1 | head -3 | grep -q "ERROR:" && log_success "Blocked." || { log_warning "Not Blocked."; false; }

echo -n "2. Wget to metadata: "
wget --timeout=2 -q -O - "http://${METADATA_IP}/latest/meta-data/" 2>&1 | head -3 | grep -q "ERROR:" && log_success "Blocked." || { log_warning "Not Blocked."; false; }

echo -n "3. Netcat to metadata (should fail): "
nc -z -w2 "${METADATA_IP}" 80 2>&1 | grep -q "failed:" && log_success "Connection failed as expected." || { log_warning "Connection succeeded!"; false; }

echo -n "4. Ping metadata (should fail): "
ping -c 2 "${METADATA_IP}" > /dev/null 2>&1 && log_warning "Ping succeeded!" || log_success "Ping failed as expected."

echo -n "5. Internet connectivity (proxy): "
curl -s --connect-timeout 3 https://ifconfig.me | head -1 | grep -q "." && log_success "Works." || { log_warning "Failed."; false; }

echo ""
echo "--- CONFIGURATION SUMMARY ---"
echo "✅ Application Wrappers: $([ -f "${METADATA_WRAPPER_DIR}/curl-wrapper" ] && echo 'Present' || echo 'MISSING')"
echo "✅ nftables Configured: $([ -f "${NFTABLES_CONF}" ] && echo 'Present' || echo 'MISSING'). Service active: $(systemctl is-active ${NFTABLES_SERVICE})"
echo "✅ nftables Rules for SSH: $(sudo nft list chain inet filter input | grep -c "tcp dport ${SSH_PORT} accept")"
echo "✅ Blackhole Routes: $(ip route | grep -c blackhole)"
echo "✅ /etc/hosts entry: $(grep -c "${METADATA_IP}" /etc/hosts)"
echo "✅ Kernel Parameters Applied: $(sysctl net.ipv4.conf.all.route_localnet | grep '= 0' && sysctl net.ipv4.ip_forward | grep '= 0' && echo 'Applied' || echo 'Not Applied')"
echo "✅ Proxy Bypass Config: $(grep -c "no_proxy=" "$ENV_VARS_FILE" || grep -c "NO_PROXY=" "$ENV_VARS_FILE")"
echo "✅ Persistence Service (${METADATA_PERSISTENCE_SERVICE}): $(systemctl is-active ${METADATA_PERSISTENCE_SERVICE} && echo 'Active' || echo 'INACTIVE')"
echo ""
log_info "Installation complete."
log_info "--------------------------------------------------------------------"
log_warning "FINAL CHECK: REBOOT AND TEST SSH ACCESS IMMEDIATELY."
log_warning "If SSH fails, the issue is MOST LIKELY in your AWS Security Group or Network ACLs."
log_warning "Ensure inbound TCP port ${SSH_PORT} is allowed from your IP."
log_warning "--------------------------------------------------------------------"

exit 0
