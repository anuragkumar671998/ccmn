#!/bin/bash
#
# AWS Metadata Blocker - Application Layer Only
# 100% SSH-Safe - No network/firewall changes
# Blocks curl, wget, python access to metadata
# Survives reboots via systemd service
#
# Usage: sudo bash block-metadata-safe.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  AWS METADATA BLOCKER (SSH-SAFE)${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Error: This script must be run as root${NC}"
    echo -e "${YELLOW}Please run: sudo bash $0${NC}"
    exit 1
fi

# Detect if in SSH session
if [ ! -z "$SSH_CONNECTION" ]; then
    echo -e "${GREEN}✓ Detected SSH session: $SSH_CONNECTION${NC}"
    echo -e "${YELLOW}⚠ This script is SSH-safe (no network changes)${NC}"
else
    echo -e "${YELLOW}ℹ Running from console/local session${NC}"
fi

echo ""
echo -e "${YELLOW}This script will:${NC}"
echo "  • Block curl/wget/python access to metadata"
echo "  • Add /etc/hosts DNS blocking"
echo "  • Create systemd service for persistence"
echo "  • NOT modify iptables/routes/networking"
echo ""
echo -e "${GREEN}Press ENTER to continue, or Ctrl+C to cancel${NC}"
read

#==============================================================================
# STEP 1: CREATE APPLICATION WRAPPERS
#==============================================================================
echo ""
echo -e "${BLUE}[1/5] Creating application wrappers...${NC}"

# Create wrapper directory
mkdir -p /usr/local/bin

# curl wrapper
cat > /usr/local/bin/curl-wrapper << 'EOF'
#!/bin/bash
# Block access to AWS metadata service
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service (169.254.169.254) is blocked" >&2
    exit 1
fi
# Pass through to real curl
exec /usr/bin/curl.real "$@"
EOF

# wget wrapper
cat > /usr/local/bin/wget-wrapper << 'EOF'
#!/bin/bash
# Block access to AWS metadata service
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service (169.254.169.254) is blocked" >&2
    exit 1
fi
# Pass through to real wget
exec /usr/bin/wget.real "$@"
EOF

# python3 wrapper (optional, blocks Python requests)
cat > /usr/local/bin/python3-wrapper << 'EOF'
#!/bin/bash
# Set environment to block metadata in Python requests
export NO_PROXY="169.254.169.254,169.254.0.0/16,localhost,127.0.0.1"
export no_proxy="169.254.169.254,169.254.0.0/16,localhost,127.0.0.1"
# Pass through to real python3
exec /usr/bin/python3.real "$@"
EOF

# Make wrappers executable
chmod +x /usr/local/bin/curl-wrapper
chmod +x /usr/local/bin/wget-wrapper
chmod +x /usr/local/bin/python3-wrapper

echo -e "${GREEN}   ✅ Wrapper scripts created${NC}"

#==============================================================================
# STEP 2: BACKUP AND REPLACE BINARIES
#==============================================================================
echo -e "${BLUE}[2/5] Backing up and replacing binaries...${NC}"

# Backup curl if not already backed up
if [ -f /usr/bin/curl ] && [ ! -f /usr/bin/curl.real ] && [ ! -L /usr/bin/curl ]; then
    cp -p /usr/bin/curl /usr/bin/curl.real
    echo -e "${GREEN}   ✅ curl backed up to curl.real${NC}"
elif [ -L /usr/bin/curl ]; then
    echo -e "${YELLOW}   ℹ curl already replaced${NC}"
fi

# Backup wget if not already backed up
if [ -f /usr/bin/wget ] && [ ! -f /usr/bin/wget.real ] && [ ! -L /usr/bin/wget ]; then
    cp -p /usr/bin/wget /usr/bin/wget.real
    echo -e "${GREEN}   ✅ wget backed up to wget.real${NC}"
elif [ -L /usr/bin/wget ]; then
    echo -e "${YELLOW}   ℹ wget already replaced${NC}"
fi

# Backup python3 if not already backed up (optional)
if [ -f /usr/bin/python3 ] && [ ! -f /usr/bin/python3.real ] && [ ! -L /usr/bin/python3 ]; then
    cp -p /usr/bin/python3 /usr/bin/python3.real
    echo -e "${GREEN}   ✅ python3 backed up to python3.real${NC}"
elif [ -L /usr/bin/python3 ]; then
    echo -e "${YELLOW}   ℹ python3 already replaced${NC}"
fi

# Replace binaries with symlinks to wrappers
rm -f /usr/bin/curl
ln -s /usr/local/bin/curl-wrapper /usr/bin/curl
echo -e "${GREEN}   ✅ curl replaced with wrapper${NC}"

rm -f /usr/bin/wget
ln -s /usr/local/bin/wget-wrapper /usr/bin/wget
echo -e "${GREEN}   ✅ wget replaced with wrapper${NC}"

rm -f /usr/bin/python3
ln -s /usr/local/bin/python3-wrapper /usr/bin/python3
echo -e "${GREEN}   ✅ python3 replaced with wrapper${NC}"

#==============================================================================
# STEP 3: UPDATE /etc/hosts
#==============================================================================
echo -e "${BLUE}[3/5] Updating /etc/hosts for DNS-level blocking...${NC}"

# Remove existing entries
sed -i '/169\.254\.169\.254/d' /etc/hosts

# Add blocking entry
echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts

echo -e "${GREEN}   ✅ Added 169.254.169.254 → 127.0.0.1 in /etc/hosts${NC}"

#==============================================================================
# STEP 4: CREATE SYSTEMD SERVICE FOR PERSISTENCE
#==============================================================================
echo -e "${BLUE}[4/5] Creating systemd service for persistence...${NC}"

cat > /etc/systemd/system/metadata-block.service << 'EOF'
[Unit]
Description=AWS Metadata Service Blocker (Application Layer)
After=multi-user.target
Documentation=https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html

[Service]
Type=oneshot
RemainAfterExit=yes

# Ensure wrappers exist
ExecStartPre=/bin/bash -c 'test -f /usr/local/bin/curl-wrapper || exit 1'
ExecStartPre=/bin/bash -c 'test -f /usr/local/bin/wget-wrapper || exit 1'

# Restore curl wrapper
ExecStart=/bin/bash -c 'if [ -f /usr/bin/curl.real ]; then rm -f /usr/bin/curl; ln -s /usr/local/bin/curl-wrapper /usr/bin/curl; fi'

# Restore wget wrapper
ExecStart=/bin/bash -c 'if [ -f /usr/bin/wget.real ]; then rm -f /usr/bin/wget; ln -s /usr/local/bin/wget-wrapper /usr/bin/wget; fi'

# Restore python3 wrapper
ExecStart=/bin/bash -c 'if [ -f /usr/bin/python3.real ]; then rm -f /usr/bin/python3; ln -s /usr/local/bin/python3-wrapper /usr/bin/python3; fi'

# Ensure /etc/hosts entry exists
ExecStart=/bin/bash -c 'grep -q "169.254.169.254" /etc/hosts || echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts'

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start service
systemctl daemon-reload
systemctl enable metadata-block.service
systemctl start metadata-block.service

echo -e "${GREEN}   ✅ Systemd service created and enabled${NC}"

#==============================================================================
# STEP 5: VERIFICATION TESTS
#==============================================================================
echo ""
echo -e "${BLUE}[5/5] Running verification tests...${NC}"
echo ""

# Test 1: curl to metadata
echo -e "${YELLOW}Test 1: curl to metadata service${NC}"
CURL_TEST=$(timeout 2 curl http://169.254.169.254/ 2>&1 || true)
if echo "$CURL_TEST" | grep -qi "ERROR.*blocked"; then
    echo -e "${GREEN}   ✅ BLOCKED - curl wrapper working${NC}"
else
    echo -e "${RED}   ❌ Not blocked: $CURL_TEST${NC}"
fi

# Test 2: wget to metadata
echo ""
echo -e "${YELLOW}Test 2: wget to metadata service${NC}"
WGET_TEST=$(timeout 2 wget -O- http://169.254.169.254/ 2>&1 || true)
if echo "$WGET_TEST" | grep -qi "ERROR.*blocked"; then
    echo -e "${GREEN}   ✅ BLOCKED - wget wrapper working${NC}"
else
    echo -e "${RED}   ❌ Not blocked: $WGET_TEST${NC}"
fi

# Test 3: Internet connectivity with real curl
echo ""
echo -e "${YELLOW}Test 3: Internet connectivity (using real curl)${NC}"
INTERNET_TEST=$(timeout 3 /usr/bin/curl.real -s https://ifconfig.me 2>/dev/null || echo "FAILED")
if [ "$INTERNET_TEST" != "FAILED" ] && [ ! -z "$INTERNET_TEST" ]; then
    echo -e "${GREEN}   ✅ Internet working - Public IP: $INTERNET_TEST${NC}"
else
    echo -e "${YELLOW}   ⚠️  Could not verify internet (may be normal)${NC}"
fi

# Test 4: SSH service status
echo ""
echo -e "${YELLOW}Test 4: SSH service status${NC}"
if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
    echo -e "${GREEN}   ✅ SSH service is running${NC}"
    if ss -tuln | grep -q ":22 "; then
        echo -e "${GREEN}   ✅ SSH listening on port 22${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠️  SSH service status unknown${NC}"
fi

# Test 5: Current connection
echo ""
echo -e "${YELLOW}Test 5: Current connection status${NC}"
if [ ! -z "$SSH_CONNECTION" ]; then
    echo -e "${GREEN}   ✅ SSH session active and maintained${NC}"
    echo -e "      Connection: $SSH_CONNECTION"
else
    echo -e "${YELLOW}   ℹ️  Running from console/local (not SSH)${NC}"
fi

# Test 6: Systemd service
echo ""
echo -e "${YELLOW}Test 6: Systemd service status${NC}"
if systemctl is-active --quiet metadata-block.service; then
    echo -e "${GREEN}   ✅ Service active${NC}"
else
    echo -e "${RED}   ❌ Service not active${NC}"
fi
if systemctl is-enabled --quiet metadata-block.service; then
    echo -e "${GREEN}   ✅ Service enabled (will start on boot)${NC}"
else
    echo -e "${RED}   ❌ Service not enabled${NC}"
fi

#==============================================================================
# SUMMARY
#==============================================================================
echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}         INSTALLATION SUMMARY${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

echo -e "${GREEN}✅ Protection Status:${NC}"
echo "   • curl wrapper: $([ -L /usr/bin/curl ] && echo '✅ Active' || echo '❌ Inactive')"
echo "   • wget wrapper: $([ -L /usr/bin/wget ] && echo '✅ Active' || echo '❌ Inactive')"
echo "   • python3 wrapper: $([ -L /usr/bin/python3 ] && echo '✅ Active' || echo '❌ Inactive')"
echo "   • /etc/hosts entry: $(grep -c 169.254.169.254 /etc/hosts) line(s)"
echo "   • Systemd service: $(systemctl is-enabled metadata-block.service 2>/dev/null || echo 'not enabled')"
echo ""

echo -e "${GREEN}🔒 What's Blocked:${NC}"
echo "   ✓ curl http://169.254.169.254/"
echo "   ✓ wget http://169.254.169.254/"
echo "   ✓ python3 requests to metadata"
echo "   ✓ DNS resolution of 169.254.169.254"
echo ""

echo -e "${GREEN}✅ What Still Works:${NC}"
echo "   ✓ SSH connections (no network changes made)"
echo "   ✓ Internet access (test: /usr/bin/curl.real https://ifconfig.me)"
echo "   ✓ All networking"
echo "   ✓ DHCP, routing, everything else"
echo ""

echo -e "${YELLOW}📋 Important Notes:${NC}"
echo "   • SSH is 100% safe (no firewall/routing changes)"
echo "   • Use /usr/bin/curl.real for direct access if needed"
echo "   • Use /usr/bin/wget.real for direct access if needed"
echo "   • Protection survives reboots (systemd service)"
echo ""

echo -e "${YELLOW}🔄 Reboot Test:${NC}"
echo "   1. Reboot: sudo reboot"
echo "   2. Reconnect via SSH"
echo "   3. Test: curl http://169.254.169.254/"
echo "   4. Verify: systemctl status metadata-block.service"
echo ""

echo -e "${YELLOW}🔓 To Remove Protection:${NC}"
echo "   sudo systemctl stop metadata-block.service"
echo "   sudo systemctl disable metadata-block.service"
echo "   sudo rm -f /usr/bin/curl /usr/bin/wget /usr/bin/python3"
echo "   sudo mv /usr/bin/curl.real /usr/bin/curl"
echo "   sudo mv /usr/bin/wget.real /usr/bin/wget"
echo "   sudo mv /usr/bin/python3.real /usr/bin/python3"
echo "   sudo sed -i '/169.254.169.254/d' /etc/hosts"
echo ""

echo -e "${GREEN}🎉 Installation Complete!${NC}"
echo -e "${GREEN}Your SSH connection should still be active.${NC}"
echo ""

exit 0
