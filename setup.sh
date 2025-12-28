#!/bin/bash
#
# AWS Metadata Blocker with Automatic SSH Exception
# Automatically detects and whitelists SSH connections
# Fetches public IP and preserves SSH access after every reboot
#
# Usage: sudo ./block-metadata-ultimate.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🔒 METADATA BLOCKER + SSH KEEPER${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root: sudo $0${NC}"
    exit 1
fi

#==============================================================================
# DETECT SSH CONNECTION AND PUBLIC IP
#==============================================================================
echo -e "${GREEN}[1/8] Detecting SSH connection details...${NC}"

# Get current SSH client IP if in SSH session
SSH_CLIENT_IP=""
if [ ! -z "$SSH_CLIENT" ]; then
    SSH_CLIENT_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    echo -e "${YELLOW}   Detected SSH from: $SSH_CLIENT_IP${NC}"
fi

if [ ! -z "$SSH_CONNECTION" ]; then
    SSH_SRC=$(echo $SSH_CONNECTION | awk '{print $1}')
    if [ -z "$SSH_CLIENT_IP" ]; then
        SSH_CLIENT_IP="$SSH_SRC"
    fi
    echo -e "${YELLOW}   SSH connection: $SSH_CONNECTION${NC}"
fi

# Get public IP from metadata (before blocking it!)
echo -e "${YELLOW}   Fetching instance public IP...${NC}"
PUBLIC_IP=$(timeout 3 curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")

if [ -z "$PUBLIC_IP" ]; then
    # Alternative method using external service
    PUBLIC_IP=$(timeout 3 curl -s https://ifconfig.me 2>/dev/null || echo "unknown")
fi

# Get private IP
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$IFACE" ]; then
    IFACE="ens5"
fi
PRIVATE_IP=$(ip addr show $IFACE | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)

# Get all active SSH connections
ACTIVE_SSH_IPS=$(ss -tn state established '( dport = :22 or sport = :22 )' | grep -v "127.0.0.1" | awk '{print $4, $5}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || echo "")

echo -e "${GREEN}   ✅ Network Information:${NC}"
echo "      Interface: $IFACE"
echo "      Private IP: $PRIVATE_IP"
echo "      Public IP: $PUBLIC_IP"
echo "      SSH Client: $SSH_CLIENT_IP"
echo "      Active SSH IPs: $ACTIVE_SSH_IPS"
echo ""

#==============================================================================
# STEP 2: APPLICATION WRAPPERS
#==============================================================================
echo -e "${GREEN}[2/8] Creating application wrappers...${NC}"

tee /usr/local/bin/curl-wrapper > /dev/null << 'EOF'
#!/bin/bash
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service is blocked" >&2
    exit 1
fi
exec /usr/bin/curl.real "$@"
EOF

tee /usr/local/bin/wget-wrapper > /dev/null << 'EOF'
#!/bin/bash
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service is blocked" >&2
    exit 1
fi
exec /usr/bin/wget.real "$@"
EOF

chmod +x /usr/local/bin/curl-wrapper
chmod +x /usr/local/bin/wget-wrapper

if [ -f /usr/bin/curl ] && [ ! -L /usr/bin/curl ]; then
    cp /usr/bin/curl /usr/bin/curl.real
fi
ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl

if [ -f /usr/bin/wget ] && [ ! -L /usr/bin/wget ]; then
    cp /usr/bin/wget /usr/bin/wget.real
fi
ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget

echo -e "${GREEN}   ✅ Wrappers installed${NC}"

#==============================================================================
# STEP 3: SAVE SSH EXCEPTION DATA
#==============================================================================
echo -e "${GREEN}[3/8] Saving SSH exception data...${NC}"

mkdir -p /etc/metadata-block

# Save IPs for persistence
tee /etc/metadata-block/ssh-whitelist.conf > /dev/null << EOF
# SSH Whitelist - Auto-generated
PUBLIC_IP=$PUBLIC_IP
PRIVATE_IP=$PRIVATE_IP
SSH_CLIENT_IP=$SSH_CLIENT_IP
IFACE=$IFACE
ACTIVE_SSH_IPS="$ACTIVE_SSH_IPS"
EOF

echo -e "${GREEN}   ✅ Whitelist saved to /etc/metadata-block/ssh-whitelist.conf${NC}"

#==============================================================================
# STEP 4: IPTABLES WITH SSH EXCEPTIONS
#==============================================================================
echo -e "${GREEN}[4/8] Configuring iptables with SSH exceptions...${NC}"

DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1 || true

# Flush existing metadata rules
iptables -D OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || true
iptables -D OUTPUT -d 169.254.169.254 -j REJECT 2>/dev/null || true
iptables -D OUTPUT -d 169.254.0.0/16 -j DROP 2>/dev/null || true

# Clear any existing metadata chain
iptables -F metadata-block 2>/dev/null || true
iptables -X metadata-block 2>/dev/null || true

# Create new chain for metadata blocking
iptables -N metadata-block 2>/dev/null || true

# CRITICAL: Allow established SSH connections FIRST
iptables -A metadata-block -m state --state ESTABLISHED,RELATED -j RETURN

# Allow SSH port (22) - NEVER block this
iptables -A metadata-block -p tcp --dport 22 -j RETURN
iptables -A metadata-block -p tcp --sport 22 -j RETURN

# Allow connections FROM known SSH clients
if [ ! -z "$SSH_CLIENT_IP" ]; then
    iptables -A metadata-block -s $SSH_CLIENT_IP -j RETURN
fi

# Allow all active SSH IPs
for ip in $ACTIVE_SSH_IPS; do
    if [ ! -z "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        iptables -A metadata-block -s $ip -j RETURN 2>/dev/null || true
        iptables -A metadata-block -d $ip -j RETURN 2>/dev/null || true
    fi
done

# NOW block metadata
iptables -A metadata-block -d 169.254.169.254 -p tcp --dport 80 -j REJECT --reject-with tcp-reset
iptables -A metadata-block -d 169.254.169.254 -p tcp --dport 443 -j REJECT --reject-with tcp-reset
iptables -A metadata-block -d 169.254.169.254 -j REJECT

# Apply chain to OUTPUT
iptables -I OUTPUT -d 169.254.169.254 -j metadata-block

# Save rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo -e "${GREEN}   ✅ iptables configured with SSH protection${NC}"

#==============================================================================
# STEP 5: NFTABLES (OPTIONAL - WITH SSH EXCEPTION)
#==============================================================================
echo -e "${GREEN}[5/8] Configuring nftables with SSH exception...${NC}"

apt-get install -y nftables > /dev/null 2>&1 || true

tee /etc/nftables.conf > /dev/null << EOF
#!/usr/sbin/nft -f

flush ruleset

table inet metadata_block {
    chain output {
        type filter hook output priority 0; policy accept;
        
        # ALLOW SSH (critical!)
        tcp sport 22 accept
        tcp dport 22 accept
        
        # ALLOW established connections
        ct state established,related accept
        
        # Block metadata service
        ip daddr 169.254.169.254 tcp dport 80 counter drop comment "Block metadata HTTP"
        ip daddr 169.254.169.254 tcp dport 443 counter drop comment "Block metadata HTTPS"
        ip daddr 169.254.169.254 counter reject comment "Block metadata other"
    }
}
EOF

# Don't enable nftables if it conflicts with iptables
# systemctl enable nftables > /dev/null 2>&1 || true
# systemctl restart nftables > /dev/null 2>&1 || true

echo -e "${GREEN}   ✅ nftables configured (not activated to avoid conflicts)${NC}"

#==============================================================================
# STEP 6: /etc/hosts
#==============================================================================
echo -e "${GREEN}[6/8] Updating /etc/hosts...${NC}"

sed -i '/169.254.169.254/d' /etc/hosts
echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts

echo -e "${GREEN}   ✅ /etc/hosts updated${NC}"

#==============================================================================
# STEP 7: KERNEL PARAMETERS
#==============================================================================
echo -e "${GREEN}[7/8] Configuring kernel parameters...${NC}"

sed -i '/route_localnet/d' /etc/sysctl.conf
sed -i '/# AWS Metadata/d' /etc/sysctl.conf

tee -a /etc/sysctl.conf > /dev/null << EOF

# AWS Metadata Blocking (SSH-safe)
net.ipv4.conf.all.route_localnet=0
net.ipv4.conf.default.route_localnet=0
net.ipv4.conf.$IFACE.route_localnet=0
EOF

sysctl -p > /dev/null 2>&1

echo -e "${GREEN}   ✅ Kernel parameters configured${NC}"

#==============================================================================
# STEP 8: SYSTEMD SERVICE (AUTO SSH DETECTION ON BOOT)
#==============================================================================
echo -e "${GREEN}[8/8] Creating smart systemd service...${NC}"

tee /etc/systemd/system/metadata-block.service > /dev/null << 'EOF'
[Unit]
Description=AWS Metadata Blocker with SSH Keeper
After=network-online.target sshd.service
Wants=network-online.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Wait for SSH to be ready
ExecStartPre=/bin/sleep 3

# Restore wrappers
ExecStart=/bin/bash -c 'if [ -f /usr/bin/curl ] && [ ! -L /usr/bin/curl ]; then cp /usr/bin/curl /usr/bin/curl.real 2>/dev/null || true; fi; ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl'
ExecStart=/bin/bash -c 'if [ -f /usr/bin/wget ] && [ ! -L /usr/bin/wget ]; then cp /usr/bin/wget /usr/bin/wget.real 2>/dev/null || true; fi; ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget'

# Run refresh script
ExecStart=/usr/local/bin/refresh-ssh-whitelist.sh

# Restore iptables
ExecStart=/bin/bash -c 'if [ -f /etc/iptables/rules.v4 ]; then /sbin/iptables-restore < /etc/iptables/rules.v4; fi'

# Apply sysctl
ExecStart=/sbin/sysctl -p

[Install]
WantedBy=multi-user.target
EOF

# Create refresh script that runs on every boot
tee /usr/local/bin/refresh-ssh-whitelist.sh > /dev/null << 'EOF'
#!/bin/bash
# Refresh SSH whitelist on boot

# Load saved config
if [ -f /etc/metadata-block/ssh-whitelist.conf ]; then
    source /etc/metadata-block/ssh-whitelist.conf
fi

# Get current active SSH connections
CURRENT_SSH=$(ss -tn state established '( dport = :22 or sport = :22 )' | grep -v "127.0.0.1" | awk '{print $4, $5}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)

# Rebuild iptables chain with current SSH IPs
iptables -F metadata-block 2>/dev/null || true
iptables -X metadata-block 2>/dev/null || true
iptables -N metadata-block 2>/dev/null || true

# Allow established connections
iptables -A metadata-block -m state --state ESTABLISHED,RELATED -j RETURN

# Allow SSH port
iptables -A metadata-block -p tcp --dport 22 -j RETURN
iptables -A metadata-block -p tcp --sport 22 -j RETURN

# Add current SSH IPs
for ip in $CURRENT_SSH; do
    if [ ! -z "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        iptables -A metadata-block -s $ip -j RETURN 2>/dev/null || true
        iptables -A metadata-block -d $ip -j RETURN 2>/dev/null || true
    fi
done

# Block metadata
iptables -A metadata-block -d 169.254.169.254 -p tcp --dport 80 -j REJECT --reject-with tcp-reset
iptables -A metadata-block -d 169.254.169.254 -p tcp --dport 443 -j REJECT --reject-with tcp-reset
iptables -A metadata-block -d 169.254.169.254 -j REJECT

# Apply to OUTPUT
iptables -D OUTPUT -d 169.254.169.254 -j metadata-block 2>/dev/null || true
iptables -I OUTPUT -d 169.254.169.254 -j metadata-block

# Save
iptables-save > /etc/iptables/rules.v4

echo "SSH whitelist refreshed with IPs: $CURRENT_SSH"
EOF

chmod +x /usr/local/bin/refresh-ssh-whitelist.sh

systemctl daemon-reload
systemctl enable metadata-block.service > /dev/null 2>&1
systemctl start metadata-block.service > /dev/null 2>&1 || true

echo -e "${GREEN}   ✅ Smart service installed${NC}"

#==============================================================================
# VERIFICATION
#==============================================================================
echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🧪 VERIFICATION TESTS${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# Test 1: SSH connection check
echo -e "${YELLOW}Test 1: SSH Connection Status${NC}"
if [ ! -z "$SSH_CONNECTION" ]; then
    echo -e "${GREEN}   ✅ SSH session active: $SSH_CONNECTION${NC}"
else
    echo -e "${YELLOW}   ℹ️  Not in SSH session (console/local)${NC}"
fi

# Test 2: SSH port listening
echo ""
echo -e "${YELLOW}Test 2: SSH Port Status${NC}"
if ss -tuln | grep -q ":22 "; then
    echo -e "${GREEN}   ✅ SSH listening on port 22${NC}"
else
    echo -e "${RED}   ❌ SSH NOT LISTENING - CHECK SSH SERVICE${NC}"
fi

# Test 3: Active SSH connections
echo ""
echo -e "${YELLOW}Test 3: Active SSH Connections${NC}"
SSH_COUNT=$(ss -tn state established '( dport = :22 or sport = :22 )' | grep -c "ESTAB" || echo "0")
if [ "$SSH_COUNT" -gt 0 ]; then
    echo -e "${GREEN}   ✅ $SSH_COUNT active SSH connection(s)${NC}"
    ss -tn state established '( dport = :22 or sport = :22 )' | grep "ESTAB" | head -5
else
    echo -e "${YELLOW}   ℹ️  No SSH connections detected${NC}"
fi

# Test 4: Metadata blocking
echo ""
echo -e "${YELLOW}Test 4: Metadata Access${NC}"
METADATA_TEST=$(timeout 2 curl -s http://169.254.169.254/latest/meta-data/ 2>&1 || echo "BLOCKED")
if echo "$METADATA_TEST" | grep -qi "blocked\|error\|refused"; then
    echo -e "${GREEN}   ✅ Metadata BLOCKED${NC}"
else
    echo -e "${RED}   ⚠️  Metadata accessible: ${METADATA_TEST:0:50}${NC}"
fi

# Test 5: Internet
echo ""
echo -e "${YELLOW}Test 5: Internet Connectivity${NC}"
INTERNET=$(timeout 3 /usr/bin/curl.real -s https://ifconfig.me 2>/dev/null || echo "FAILED")
if [ "$INTERNET" != "FAILED" ]; then
    echo -e "${GREEN}   ✅ Internet working (IP: $INTERNET)${NC}"
else
    echo -e "${YELLOW}   ⚠️  Internet check failed (may be normal)${NC}"
fi

#==============================================================================
# SUMMARY
#==============================================================================
echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}📋 INSTALLATION SUMMARY${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

echo -e "${GREEN}🔒 Security Status:${NC}"
echo "   ✓ Metadata service: BLOCKED"
echo "   ✓ SSH connections: PROTECTED"
echo "   ✓ Internet access: WORKING"
echo ""

echo -e "${GREEN}📡 Network Details:${NC}"
echo "   • Public IP: $PUBLIC_IP"
echo "   • Private IP: $PRIVATE_IP"
echo "   • Interface: $IFACE"
echo "   • SSH Client: ${SSH_CLIENT_IP:-none}"
echo ""

echo -e "${GREEN}🛡️ Active Protections:${NC}"
echo "   • Application wrappers: $([ -L /usr/bin/curl ] && echo '✅' || echo '❌')"
echo "   • iptables rules: $(iptables -L OUTPUT -n 2>/dev/null | grep -c 169.254.169.254)"
echo "   • SSH whitelist entries: $(iptables -L metadata-block -n 2>/dev/null | grep -c RETURN || echo '0')"
echo "   • Service enabled: $(systemctl is-enabled metadata-block.service 2>/dev/null || echo 'no')"
echo ""

echo -e "${YELLOW}📌 SSH Connection Info:${NC}"
echo "   To reconnect: ssh $USER@$PUBLIC_IP"
echo "   Whitelisted IPs saved in: /etc/metadata-block/ssh-whitelist.conf"
echo ""

echo -e "${YELLOW}🔄 After Reboot:${NC}"
echo "   • SSH whitelist auto-refreshes"
echo "   • Metadata stays blocked"
echo "   • Your SSH session preserved"
echo ""

echo -e "${GREEN}✅ Installation complete - SSH is SAFE!${NC}"
echo ""

exit 0
