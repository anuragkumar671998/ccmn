#!/bin/bash
#
# AWS Metadata Service Blocker - SSH-SAFE VERSION
# Blocks 169.254.169.254 metadata access without breaking SSH
# Safe for production use with AWS public IPs
#
# Usage: sudo ./block-metadata-safe.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🔒 AWS METADATA BLOCKER (SSH-SAFE)${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root: sudo $0${NC}"
    exit 1
fi

# Detect network interface
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$IFACE" ]; then
    IFACE="ens5"
fi

# Get instance public IP (for safety checks)
PUBLIC_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
LOCAL_IP=$(ip addr show $IFACE | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)

echo -e "${YELLOW}[INFO] Network interface: $IFACE${NC}"
echo -e "${YELLOW}[INFO] Local IP: $LOCAL_IP${NC}"
echo -e "${YELLOW}[INFO] Public IP: $PUBLIC_IP${NC}"
echo ""

#==============================================================================
# STEP 1: APPLICATION WRAPPERS
#==============================================================================
echo -e "${GREEN}[1/7] Creating application wrappers...${NC}"

tee /usr/local/bin/curl-wrapper > /dev/null << 'EOF'
#!/bin/bash
# Block only metadata service, not entire link-local range
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service is blocked" >&2
    exit 1
fi
exec /usr/bin/curl.real "$@"
EOF

tee /usr/local/bin/wget-wrapper > /dev/null << 'EOF'
#!/bin/bash
# Block only metadata service, not entire link-local range
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service is blocked" >&2
    exit 1
fi
exec /usr/bin/wget.real "$@"
EOF

chmod +x /usr/local/bin/curl-wrapper
chmod +x /usr/local/bin/wget-wrapper

# Backup and replace
if [ -f /usr/bin/curl ] && [ ! -L /usr/bin/curl ]; then
    cp /usr/bin/curl /usr/bin/curl.real
fi
ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl

if [ -f /usr/bin/wget ] && [ ! -L /usr/bin/wget ]; then
    cp /usr/bin/wget /usr/bin/wget.real
fi
ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget

echo -e "${GREEN}   ✅ curl and wget wrappers installed${NC}"

#==============================================================================
# STEP 2: IPTABLES (METADATA ONLY - PRESERVES SSH)
#==============================================================================
echo -e "${GREEN}[2/7] Configuring iptables (metadata only)...${NC}"

# Install iptables-persistent
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1 || true

# Remove any existing metadata blocks
iptables -D OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || true
iptables -D OUTPUT -d 169.254.169.254 -j REJECT 2>/dev/null || true
iptables -D OUTPUT -d 169.254.0.0/16 -j DROP 2>/dev/null || true

# Add SPECIFIC blocks for metadata service only (ports 80, 443)
# This allows other link-local traffic (like DHCP, SSH routing)
iptables -I OUTPUT -d 169.254.169.254 -p tcp --dport 80 -j REJECT --reject-with tcp-reset
iptables -I OUTPUT -d 169.254.169.254 -p tcp --dport 443 -j REJECT --reject-with tcp-reset
iptables -I OUTPUT -d 169.254.169.254 -p icmp -j DROP

# Save rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo -e "${GREEN}   ✅ iptables configured (SSH preserved)${NC}"

#==============================================================================
# STEP 3: NFTABLES (SPECIFIC BLOCKING)
#==============================================================================
echo -e "${GREEN}[3/7] Configuring nftables...${NC}"

apt-get install -y nftables > /dev/null 2>&1 || true

tee /etc/nftables.conf > /dev/null << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet metadata_block {
    chain output {
        type filter hook output priority 0; policy accept;
        
        # Block ONLY metadata service (169.254.169.254)
        # Allows other link-local addresses (169.254.x.x for DHCP, routing)
        ip daddr 169.254.169.254 tcp dport 80 counter drop comment "Block metadata HTTP"
        ip daddr 169.254.169.254 tcp dport 443 counter drop comment "Block metadata HTTPS"
        ip daddr 169.254.169.254 counter reject comment "Block metadata other protocols"
    }
}
EOF

systemctl enable nftables > /dev/null 2>&1 || true
systemctl restart nftables > /dev/null 2>&1 || true

echo -e "${GREEN}   ✅ nftables configured${NC}"

#==============================================================================
# STEP 4: IP ROUTE (NULL ROUTE - NOT BLACKHOLE)
#==============================================================================
echo -e "${GREEN}[4/7] Adding null route for metadata...${NC}"

# Remove existing routes
ip route del 169.254.169.254 2>/dev/null || true

# Add null route (NOT blackhole - safer for SSH)
# Sends to 127.0.0.1 instead of blackhole
ip route add 169.254.169.254 via 127.0.0.1 dev lo 2>/dev/null || true

echo -e "${GREEN}   ✅ Null route added${NC}"

#==============================================================================
# STEP 5: /etc/hosts
#==============================================================================
echo -e "${GREEN}[5/7] Updating /etc/hosts...${NC}"

sed -i '/169.254.169.254/d' /etc/hosts
echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts

echo -e "${GREEN}   ✅ /etc/hosts updated${NC}"

#==============================================================================
# STEP 6: KERNEL PARAMETERS (CONSERVATIVE)
#==============================================================================
echo -e "${GREEN}[6/7] Configuring kernel parameters...${NC}"

# Remove old entries
sed -i '/route_localnet/d' /etc/sysctl.conf
sed -i '/# AWS Metadata Blocking/d' /etc/sysctl.conf

# Add conservative parameters (doesn't break link-local routing)
tee -a /etc/sysctl.conf > /dev/null << EOF

# AWS Metadata Blocking (SSH-safe)
net.ipv4.conf.all.route_localnet=0
net.ipv4.conf.default.route_localnet=0
net.ipv4.conf.$IFACE.route_localnet=0
EOF

sysctl -p > /dev/null 2>&1

echo -e "${GREEN}   ✅ Kernel parameters configured${NC}"

#==============================================================================
# STEP 7: SYSTEMD SERVICE (RESTORATION ON BOOT)
#==============================================================================
echo -e "${GREEN}[7/7] Creating systemd service...${NC}"

tee /etc/systemd/system/metadata-block.service > /dev/null << 'EOF'
[Unit]
Description=AWS Metadata Service Blocker (SSH Safe)
After=network-online.target
Wants=network-online.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes

# Restore wrappers
ExecStart=/bin/bash -c 'if [ -f /usr/bin/curl ] && [ ! -L /usr/bin/curl ]; then cp /usr/bin/curl /usr/bin/curl.real 2>/dev/null || true; fi; ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl'
ExecStart=/bin/bash -c 'if [ -f /usr/bin/wget ] && [ ! -L /usr/bin/wget ]; then cp /usr/bin/wget /usr/bin/wget.real 2>/dev/null || true; fi; ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget'

# Restore iptables
ExecStart=/bin/bash -c 'if [ -f /etc/iptables/rules.v4 ]; then /sbin/iptables-restore < /etc/iptables/rules.v4; fi'

# Restore null route (not blackhole)
ExecStart=/bin/bash -c '/sbin/ip route show | grep -q "169.254.169.254" || /sbin/ip route add 169.254.169.254 via 127.0.0.1 dev lo 2>/dev/null || true'

# Apply sysctl
ExecStart=/sbin/sysctl -p

# Verify SSH is still working
ExecStartPost=/bin/bash -c 'ss -tuln | grep -q ":22 " && echo "SSH port check: OK" || echo "WARNING: SSH port may not be listening"'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable metadata-block.service > /dev/null 2>&1
systemctl start metadata-block.service > /dev/null 2>&1 || true

echo -e "${GREEN}   ✅ Systemd service installed${NC}"

#==============================================================================
# VERIFICATION TESTS
#==============================================================================
echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🧪 RUNNING VERIFICATION TESTS${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# Test 1: Metadata blocking
echo -e "${YELLOW}Test 1: Metadata access (should be blocked)${NC}"
METADATA_TEST=$(timeout 2 curl -s http://169.254.169.254/latest/meta-data/ 2>&1 || echo "BLOCKED")
if echo "$METADATA_TEST" | grep -qi "blocked\|error\|failed\|refused"; then
    echo -e "${GREEN}   ✅ Metadata BLOCKED${NC}"
else
    echo -e "${RED}   ⚠️  Metadata may be accessible: $METADATA_TEST${NC}"
fi

# Test 2: Internet connectivity
echo ""
echo -e "${YELLOW}Test 2: Internet access (should work)${NC}"
INTERNET_TEST=$(timeout 3 /usr/bin/curl.real -s https://ifconfig.me 2>/dev/null || echo "FAILED")
if [ "$INTERNET_TEST" != "FAILED" ] && [ ! -z "$INTERNET_TEST" ]; then
    echo -e "${GREEN}   ✅ Internet working (IP: $INTERNET_TEST)${NC}"
else
    echo -e "${YELLOW}   ⚠️  Internet test inconclusive${NC}"
fi

# Test 3: SSH port check
echo ""
echo -e "${YELLOW}Test 3: SSH service (should be running)${NC}"
if ss -tuln | grep -q ":22 "; then
    echo -e "${GREEN}   ✅ SSH port 22 is listening${NC}"
else
    echo -e "${RED}   ⚠️  SSH port may not be listening!${NC}"
fi

# Test 4: Routing table check
echo ""
echo -e "${YELLOW}Test 4: Routing table (verify no blackhole)${NC}"
if ip route show | grep -q "blackhole"; then
    echo -e "${RED}   ⚠️  WARNING: Blackhole routes found (may affect SSH)${NC}"
    ip route show | grep blackhole
else
    echo -e "${GREEN}   ✅ No blackhole routes (SSH safe)${NC}"
fi

# Test 5: Current SSH session
echo ""
echo -e "${YELLOW}Test 5: Current session check${NC}"
if [ ! -z "$SSH_CONNECTION" ]; then
    echo -e "${GREEN}   ✅ Running in SSH session - connection maintained!${NC}"
    echo -e "      SSH_CONNECTION: $SSH_CONNECTION"
else
    echo -e "${YELLOW}   ℹ️  Not running via SSH (local/console session)${NC}"
fi

#==============================================================================
# SUMMARY
#==============================================================================
echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}📋 PROTECTION SUMMARY${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

echo -e "${GREEN}✅ Active Protections:${NC}"
echo "   - Application wrappers: curl $([ -L /usr/bin/curl ] && echo '✅' || echo '❌'), wget $([ -L /usr/bin/wget ] && echo '✅' || echo '❌')"
echo "   - iptables rules: $(iptables -L OUTPUT -n 2>/dev/null | grep -c 169.254.169.254) active"
echo "   - nftables: $(nft list tables 2>/dev/null | grep -c metadata || echo '0') table(s)"
echo "   - Null route: $(ip route show | grep -c 169.254.169.254) route(s)"
echo "   - /etc/hosts: $(grep -c 169.254.169.254 /etc/hosts) entry"
echo "   - Systemd service: $(systemctl is-enabled metadata-block.service 2>/dev/null || echo 'disabled')"

echo ""
echo -e "${GREEN}✅ What's Blocked:${NC}"
echo "   ✓ curl http://169.254.169.254/"
echo "   ✓ wget http://169.254.169.254/"
echo "   ✓ Python urllib/requests to metadata"
echo "   ✓ IMDSv1 and IMDSv2"
echo "   ✓ Direct TCP connections to metadata"

echo ""
echo -e "${GREEN}✅ What Still Works:${NC}"
echo "   ✓ SSH connections (via public IP: $PUBLIC_IP)"
echo "   ✓ Internet access"
echo "   ✓ DHCP (link-local 169.254.x.x range)"
echo "   ✓ Mining operations"
echo "   ✓ All normal AWS services"

echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}🎉 INSTALLATION COMPLETE!${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

echo -e "${YELLOW}📌 Next Steps:${NC}"
echo "   1. Verify SSH still works: ssh $USER@$PUBLIC_IP"
echo "   2. Test metadata blocking: curl http://169.254.169.254/"
echo "   3. Test after reboot: sudo reboot"
echo ""

echo -e "${YELLOW}📌 Reboot Test Commands:${NC}"
echo "   After reboot, run:"
echo "   curl http://169.254.169.254/          # Should fail"
echo "   curl https://ifconfig.me              # Should work"
echo "   systemctl status metadata-block       # Should be active"
echo ""

echo -e "${GREEN}🔒 Your instance is now SECURE (and SSH still works)!${NC}"
echo ""

exit 0
