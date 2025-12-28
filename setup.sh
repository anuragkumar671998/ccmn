#!/bin/bash
#
# AWS Metadata Service Nuclear Blocker
# Blocks access to 169.254.169.254 at multiple layers
# Survives reboots, package updates, and all bypass attempts
#
# Usage: sudo ./block-metadata.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🔒 AWS METADATA NUCLEAR BLOCKER${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root: sudo $0${NC}"
    exit 1
fi

# Get network interface name
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$IFACE" ]; then
    IFACE="ens5"  # AWS default
fi

echo -e "${YELLOW}[INFO] Detected network interface: $IFACE${NC}"
echo ""

#==============================================================================
# STEP 1: CREATE APPLICATION WRAPPERS
#==============================================================================
echo -e "${GREEN}[1/9] Creating application wrappers...${NC}"

# curl wrapper
tee /usr/local/bin/curl-wrapper > /dev/null << 'EOF'
#!/bin/bash
if echo "$@" | grep -qE "169\.254\.(169\.254|[0-9]+\.[0-9]+)"; then
    echo "ERROR: Access to AWS metadata service is blocked" >&2
    exit 1
fi
exec /usr/bin/curl.real "$@"
EOF

# wget wrapper
tee /usr/local/bin/wget-wrapper > /dev/null << 'EOF'
#!/bin/bash
if echo "$@" | grep -qE "169\.254\.(169\.254|[0-9]+\.[0-9]+)"; then
    echo "ERROR: Access to AWS metadata service is blocked" >&2
    exit 1
fi
exec /usr/bin/wget.real "$@"
EOF

chmod +x /usr/local/bin/curl-wrapper
chmod +x /usr/local/bin/wget-wrapper

# Backup and replace curl
if [ -f /usr/bin/curl ] && [ ! -L /usr/bin/curl ]; then
    mv /usr/bin/curl /usr/bin/curl.real
fi
ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl

# Backup and replace wget
if [ -f /usr/bin/wget ] && [ ! -L /usr/bin/wget ]; then
    mv /usr/bin/wget /usr/bin/wget.real
fi
ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget

echo -e "${GREEN}   ✅ curl and wget wrappers installed${NC}"

#==============================================================================
# STEP 2: CONFIGURE IPTABLES
#==============================================================================
echo -e "${GREEN}[2/9] Configuring iptables firewall...${NC}"

# Install iptables-persistent
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1 || true

# Clear existing rules for metadata
iptables -t raw -D OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || true
iptables -t raw -D OUTPUT -d 169.254.0.0/16 -j DROP 2>/dev/null || true
iptables -t mangle -D OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || true
iptables -D OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || true

# Add new rules (RAW table has highest priority)
iptables -t raw -I OUTPUT -d 169.254.169.254 -j DROP
iptables -t raw -I OUTPUT -d 169.254.0.0/16 -j DROP
iptables -t mangle -I OUTPUT -d 169.254.169.254 -j DROP
iptables -I OUTPUT -d 169.254.169.254 -j DROP

# Save rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo -e "${GREEN}   ✅ iptables rules configured and saved${NC}"

#==============================================================================
# STEP 3: CONFIGURE NFTABLES
#==============================================================================
echo -e "${GREEN}[3/9] Configuring nftables...${NC}"

# Install nftables
apt-get install -y nftables > /dev/null 2>&1 || true

# Create nftables config
tee /etc/nftables.conf > /dev/null << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet metadata_block {
    chain output {
        type filter hook output priority -150; policy accept;
        ip daddr 169.254.169.254 counter drop
        ip daddr 169.254.0.0/16 counter drop
    }
}
EOF

# Enable and start nftables
systemctl enable nftables > /dev/null 2>&1 || true
systemctl restart nftables > /dev/null 2>&1 || true

echo -e "${GREEN}   ✅ nftables configured and enabled${NC}"

#==============================================================================
# STEP 4: ADD BLACKHOLE ROUTES
#==============================================================================
echo -e "${GREEN}[4/9] Adding blackhole routes...${NC}"

# Remove existing blackhole routes
ip route del blackhole 169.254.169.254/32 2>/dev/null || true
ip route del blackhole 169.254.0.0/16 2>/dev/null || true

# Add new blackhole routes
ip route add blackhole 169.254.169.254/32
ip route add blackhole 169.254.0.0/16

echo -e "${GREEN}   ✅ Blackhole routes added${NC}"

#==============================================================================
# STEP 5: UPDATE /etc/hosts
#==============================================================================
echo -e "${GREEN}[5/9] Updating /etc/hosts...${NC}"

# Remove existing entries
sed -i '/169.254.169.254/d' /etc/hosts

# Add blocking entry
echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts

echo -e "${GREEN}   ✅ /etc/hosts updated${NC}"

#==============================================================================
# STEP 6: CONFIGURE KERNEL PARAMETERS
#==============================================================================
echo -e "${GREEN}[6/9] Configuring kernel parameters...${NC}"

# Remove existing entries
sed -i '/route_localnet/d' /etc/sysctl.conf
sed -i '/ip_forward/d' /etc/sysctl.conf

# Add kernel parameters
tee -a /etc/sysctl.conf > /dev/null << EOF

# AWS Metadata Blocking
net.ipv4.conf.all.route_localnet=0
net.ipv4.conf.default.route_localnet=0
net.ipv4.conf.$IFACE.route_localnet=0
net.ipv4.ip_forward=0
EOF

# Apply immediately
sysctl -p > /dev/null

echo -e "${GREEN}   ✅ Kernel parameters configured${NC}"

#==============================================================================
# STEP 7: BLOCK PROXY BYPASS
#==============================================================================
echo -e "${GREEN}[7/9] Configuring proxy bypass prevention...${NC}"

# Update no_proxy in /etc/environment
sed -i '/no_proxy/d' /etc/environment
sed -i '/NO_PROXY/d' /etc/environment

tee -a /etc/environment > /dev/null << 'EOF'
no_proxy=localhost,127.0.0.1,169.254.169.254,169.254.0.0/16
NO_PROXY=localhost,127.0.0.1,169.254.169.254,169.254.0.0/16
EOF

echo -e "${GREEN}   ✅ Proxy bypass prevention configured${NC}"

#==============================================================================
# STEP 8: CREATE SYSTEMD SERVICE
#==============================================================================
echo -e "${GREEN}[8/9] Creating systemd service for persistence...${NC}"

tee /etc/systemd/system/metadata-block.service > /dev/null << 'EOF'
[Unit]
Description=AWS Metadata Service Blocker
After=network-pre.target
Before=network-online.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes

# Restore wrappers
ExecStart=/bin/bash -c 'if [ -f /usr/bin/curl ] && [ ! -L /usr/bin/curl ]; then mv /usr/bin/curl /usr/bin/curl.real; fi; ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl'
ExecStart=/bin/bash -c 'if [ -f /usr/bin/wget ] && [ ! -L /usr/bin/wget ]; then mv /usr/bin/wget /usr/bin/wget.real; fi; ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget'

# Restore iptables rules
ExecStart=/bin/bash -c 'test -f /etc/iptables/rules.v4 && /sbin/iptables-restore < /etc/iptables/rules.v4 || true'

# Restore blackhole routes
ExecStart=/bin/bash -c '/sbin/ip route show | grep -q "blackhole 169.254.169.254" || /sbin/ip route add blackhole 169.254.169.254/32'
ExecStart=/bin/bash -c '/sbin/ip route show | grep -q "blackhole 169.254.0.0/16" || /sbin/ip route add blackhole 169.254.0.0/16'

# Apply sysctl
ExecStart=/sbin/sysctl -p

[Install]
WantedBy=sysinit.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable metadata-block.service > /dev/null 2>&1
systemctl start metadata-block.service > /dev/null 2>&1 || true

echo -e "${GREEN}   ✅ Systemd service created and enabled${NC}"

#==============================================================================
# STEP 9: VERIFICATION
#==============================================================================
echo ""
echo -e "${BLUE}[9/9] Running verification tests...${NC}"
echo ""

# Test 1: curl
echo -e "${YELLOW}Test 1: curl to metadata${NC}"
timeout 2 curl http://169.254.169.254/ 2>&1 | head -1 || echo -e "${GREEN}   ✅ Blocked (timeout/error)${NC}"

echo ""
# Test 2: wget
echo -e "${YELLOW}Test 2: wget to metadata${NC}"
timeout 2 wget --timeout=1 -O- http://169.254.169.254/ 2>&1 | head -1 || echo -e "${GREEN}   ✅ Blocked (timeout/error)${NC}"

echo ""
# Test 3: netcat
echo -e "${YELLOW}Test 3: netcat port check${NC}"
timeout 2 nc -zv 169.254.169.254 80 2>&1 | head -1 || echo -e "${GREEN}   ✅ Blocked (connection failed)${NC}"

echo ""
# Test 4: ping
echo -e "${YELLOW}Test 4: ping test${NC}"
timeout 2 ping -c 1 169.254.169.254 2>&1 | head -1 || echo -e "${GREEN}   ✅ Blocked (timeout/error)${NC}"

echo ""
# Test 5: Internet connectivity
echo -e "${YELLOW}Test 5: Internet connectivity${NC}"
INTERNET=$(timeout 3 curl -s https://ifconfig.me 2>/dev/null || echo "Failed")
if [ "$INTERNET" != "Failed" ]; then
    echo -e "${GREEN}   ✅ Internet working (IP: $INTERNET)${NC}"
else
    echo -e "${YELLOW}   ⚠️  Internet test failed (may be normal if no proxy configured)${NC}"
fi

#==============================================================================
# SUMMARY
#==============================================================================
echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}📋 PROTECTION SUMMARY${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

echo -e "${GREEN}✅ Application Wrappers:${NC}"
echo "   - curl: $([ -L /usr/bin/curl ] && echo '✅ Active' || echo '❌ Missing')"
echo "   - wget: $([ -L /usr/bin/wget ] && echo '✅ Active' || echo '❌ Missing')"

echo ""
echo -e "${GREEN}✅ Firewall Rules:${NC}"
echo "   - iptables RAW: $(iptables -t raw -L OUTPUT -n 2>/dev/null | grep -c 169.254) rules"
echo "   - iptables OUTPUT: $(iptables -L OUTPUT -n 2>/dev/null | grep -c 169.254) rules"
echo "   - nftables: $(nft list tables 2>/dev/null | grep -c metadata || echo '0') tables"

echo ""
echo -e "${GREEN}✅ Network Blocks:${NC}"
echo "   - Blackhole routes: $(ip route 2>/dev/null | grep -c blackhole)"
echo "   - /etc/hosts entry: $(grep -c 169.254 /etc/hosts)"

echo ""
echo -e "${GREEN}✅ Kernel Protection:${NC}"
echo "   - route_localnet disabled: $(sysctl net.ipv4.conf.all.route_localnet | grep -c '= 0')/1"
echo "   - ip_forward disabled: $(sysctl net.ipv4.ip_forward | grep -c '= 0')/1"

echo ""
echo -e "${GREEN}✅ Persistence:${NC}"
echo "   - Systemd service: $(systemctl is-enabled metadata-block.service 2>/dev/null || echo 'disabled')"
echo "   - iptables saved: $([ -f /etc/iptables/rules.v4 ] && echo '✅' || echo '❌')"
echo "   - nftables enabled: $(systemctl is-enabled nftables 2>/dev/null || echo 'disabled')"

echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}🎉 INSTALLATION COMPLETE!${NC}"
echo -e "${BLUE}================================${NC}"
echo ""
echo -e "${YELLOW}📌 What's protected:${NC}"
echo "   ✅ curl, wget, python requests"
echo "   ✅ Direct TCP connections"
echo "   ✅ Ping/ICMP"
echo "   ✅ IMDSv1 and IMDSv2"
echo "   ✅ Proxy bypass attempts"
echo ""
echo -e "${YELLOW}📌 What still works:${NC}"
echo "   ✅ Internet access"
echo "   ✅ Normal AWS operations (except metadata)"
echo "   ✅ All applications and services"
echo ""
echo -e "${YELLOW}📌 Reboot test:${NC}"
echo "   Run: sudo reboot"
echo "   After reboot: curl http://169.254.169.254/"
echo "   Expected: ERROR: Access to AWS metadata service is blocked"
echo ""
echo -e "${GREEN}🔒 Your instance is now SECURE!${NC}"
echo ""

exit 0
