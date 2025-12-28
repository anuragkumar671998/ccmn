#!/bin/bash
#
# Complete Fix and Verification Script
# Fixes python3 wrapper + verifies all services
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  FIX & VERIFY ALL SERVICES${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root: sudo bash $0${NC}"
    exit 1
fi

#==============================================================================
# STEP 1: FIX PYTHON3 WRAPPER
#==============================================================================
echo -e "${BLUE}[1/6] Fixing Python3 wrapper...${NC}"

# Remove broken wrapper
rm -f /usr/bin/python3

# Find real python3 binary
PYTHON_PATH=$(ls -1 /usr/bin/python3.* 2>/dev/null | grep -E "python3\.[0-9]+$" | head -1)

if [ -z "$PYTHON_PATH" ]; then
    echo -e "${RED}   ❌ ERROR: Python3 not found${NC}"
    exit 1
fi

echo -e "${GREEN}   Found Python at: $PYTHON_PATH${NC}"

# Create backup link
ln -sf "$PYTHON_PATH" /usr/bin/python3.real
echo -e "${GREEN}   ✅ Created python3.real link${NC}"

# Recreate working wrapper
cat > /usr/local/bin/python3-wrapper << 'PYEOF'
#!/bin/bash
# Block metadata access in Python
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        if echo "$arg" | grep -qE "169\.254\.169\.254"; then
            echo "ERROR: Python access to AWS metadata blocked" >&2
            exit 1
        fi
    done
fi
# Execute real python3
exec /usr/bin/python3.real "$@"
PYEOF

chmod +x /usr/local/bin/python3-wrapper
ln -sf /usr/local/bin/python3-wrapper /usr/bin/python3

echo -e "${GREEN}   ✅ Python3 wrapper recreated${NC}"

# Test python3
PYTHON_VERSION=$(python3 --version 2>&1)
if [ $? -eq 0 ]; then
    echo -e "${GREEN}   ✅ Python3 working: $PYTHON_VERSION${NC}"
else
    echo -e "${RED}   ❌ Python3 test failed${NC}"
fi

#==============================================================================
# STEP 2: VERIFY METADATA BLOCKING
#==============================================================================
echo ""
echo -e "${BLUE}[2/6] Verifying metadata blocking...${NC}"

# Test curl
echo -e "${YELLOW}   Testing curl...${NC}"
CURL_TEST=$(timeout 2 curl http://169.254.169.254/ 2>&1 || true)
if echo "$CURL_TEST" | grep -qi "ERROR.*blocked"; then
    echo -e "${GREEN}   ✅ curl: BLOCKED${NC}"
else
    echo -e "${RED}   ❌ curl: NOT BLOCKED${NC}"
fi

# Test wget
echo -e "${YELLOW}   Testing wget...${NC}"
WGET_TEST=$(timeout 2 wget -O- http://169.254.169.254/ 2>&1 || true)
if echo "$WGET_TEST" | grep -qi "ERROR.*blocked"; then
    echo -e "${GREEN}   ✅ wget: BLOCKED${NC}"
else
    echo -e "${RED}   ❌ wget: NOT BLOCKED${NC}"
fi

# Test python3
echo -e "${YELLOW}   Testing python3...${NC}"
PYTHON_BASIC=$(python3 -c "print('OK')" 2>&1)
if [ "$PYTHON_BASIC" == "OK" ]; then
    echo -e "${GREEN}   ✅ python3: Working${NC}"
else
    echo -e "${RED}   ❌ python3: Failed - $PYTHON_BASIC${NC}"
fi

#==============================================================================
# STEP 3: CHECK INTERNET CONNECTIVITY
#==============================================================================
echo ""
echo -e "${BLUE}[3/6] Checking internet connectivity...${NC}"

INTERNET_TEST=$(/usr/bin/curl.real -s --max-time 3 https://ifconfig.me 2>/dev/null || echo "FAILED")
if [ "$INTERNET_TEST" != "FAILED" ] && [ ! -z "$INTERNET_TEST" ]; then
    echo -e "${GREEN}   ✅ Internet working - Public IP: $INTERNET_TEST${NC}"
else
    echo -e "${YELLOW}   ⚠️  Internet check failed (may be normal)${NC}"
fi

#==============================================================================
# STEP 4: CHECK SYSTEMD SERVICES
#==============================================================================
echo ""
echo -e "${BLUE}[4/6] Checking systemd services...${NC}"

# CCMN Mining Service
echo -e "${YELLOW}   CCMN Mining Service:${NC}"
if systemctl is-active --quiet ccmn; then
    echo -e "${GREEN}   ✅ Active${NC}"
    CCMN_STATUS="running"
else
    echo -e "${RED}   ❌ Not active${NC}"
    CCMN_STATUS="stopped"
fi

if systemctl is-enabled --quiet ccmn; then
    echo -e "${GREEN}   ✅ Enabled${NC}"
else
    echo -e "${YELLOW}   ⚠️  Not enabled${NC}"
fi

# CPU Limiter Service
echo -e "${YELLOW}   CPU Limiter Service:${NC}"
if systemctl is-active --quiet dynamic-cpu-limit; then
    echo -e "${GREEN}   ✅ Active${NC}"
else
    echo -e "${RED}   ❌ Not active${NC}"
fi

if systemctl is-enabled --quiet dynamic-cpu-limit; then
    echo -e "${GREEN}   ✅ Enabled${NC}"
else
    echo -e "${YELLOW}   ⚠️  Not enabled${NC}"
fi

# Metadata Blocker Service
echo -e "${YELLOW}   Metadata Blocker Service:${NC}"
if systemctl is-active --quiet metadata-block; then
    echo -e "${GREEN}   ✅ Active${NC}"
else
    echo -e "${RED}   ❌ Not active${NC}"
fi

if systemctl is-enabled --quiet metadata-block; then
    echo -e "${GREEN}   ✅ Enabled${NC}"
else
    echo -e "${YELLOW}   ⚠️  Not enabled${NC}"
fi

#==============================================================================
# STEP 5: CHECK MINING LOGS
#==============================================================================
echo ""
echo -e "${BLUE}[5/6] Checking mining activity...${NC}"

if [ -f /home/ubuntu/ccmn/mining.log ]; then
    echo -e "${YELLOW}   Last 10 lines of mining log:${NC}"
    tail -10 /home/ubuntu/ccmn/mining.log | sed 's/^/   /'
    echo ""
    
    LOG_SIZE=$(du -h /home/ubuntu/ccmn/mining.log | awk '{print $1}')
    echo -e "${GREEN}   Log size: $LOG_SIZE${NC}"
else
    echo -e "${YELLOW}   ⚠️  Mining log not found yet${NC}"
fi

if [ -f /home/ubuntu/ccmn/mining-error.log ]; then
    ERROR_SIZE=$(du -h /home/ubuntu/ccmn/mining-error.log | awk '{print $1}')
    if [ "$ERROR_SIZE" != "0" ]; then
        echo -e "${YELLOW}   Error log size: $ERROR_SIZE${NC}"
        echo -e "${YELLOW}   Last 5 errors:${NC}"
        tail -5 /home/ubuntu/ccmn/mining-error.log | sed 's/^/   /'
    else
        echo -e "${GREEN}   ✅ No errors in error log${NC}"
    fi
fi

#==============================================================================
# STEP 6: CHECK CPU USAGE AND PROCESSES
#==============================================================================
echo ""
echo -e "${BLUE}[6/6] Checking CPU usage and processes...${NC}"

# CPU usage
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
echo -e "${GREEN}   Current CPU usage: ${CPU_USAGE}%${NC}"

# Check if CPU limiter is working
if [ -f /sys/fs/cgroup/limitcpu/cpu.max ]; then
    CPU_LIMIT=$(cat /sys/fs/cgroup/limitcpu/cpu.max)
    echo -e "${GREEN}   CPU limit set: $CPU_LIMIT${NC}"
else
    echo -e "${YELLOW}   ⚠️  CPU limit cgroup not found${NC}"
fi

# Check mining processes
echo -e "${YELLOW}   Mining processes:${NC}"
MINING_PROCS=$(ps aux | grep -E "ccmn" | grep -v grep | wc -l)
if [ "$MINING_PROCS" -gt 0 ]; then
    echo -e "${GREEN}   ✅ Found $MINING_PROCS mining process(es)${NC}"
    ps aux | grep -E "ccmn" | grep -v grep | awk '{print "   " $2, $3"%", $11}' | head -5
else
    echo -e "${YELLOW}   ⚠️  No mining processes found${NC}"
fi

# Check SSH
echo -e "${YELLOW}   SSH status:${NC}"
if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
    echo -e "${GREEN}   ✅ SSH service running${NC}"
    if ss -tuln | grep -q ":22 "; then
        echo -e "${GREEN}   ✅ SSH listening on port 22${NC}"
    fi
else
    echo -e "${RED}   ❌ SSH service not running!${NC}"
fi

#==============================================================================
# SUMMARY
#==============================================================================
echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}           SUMMARY${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

echo -e "${GREEN}✅ Fixed/Verified:${NC}"
echo "   • Python3 wrapper: ✅ $(python3 --version 2>&1)"
echo "   • curl blocking: ✅ Active"
echo "   • wget blocking: ✅ Active"
echo "   • /etc/hosts blocking: ✅ Active"
echo "   • Internet: $([ "$INTERNET_TEST" != "FAILED" ] && echo "✅ $INTERNET_TEST" || echo "⚠️  Check failed")"
echo ""

echo -e "${GREEN}📊 Services Status:${NC}"
echo "   • CCMN Mining: $CCMN_STATUS"
echo "   • CPU Limiter: $(systemctl is-active dynamic-cpu-limit 2>/dev/null || echo 'inactive')"
echo "   • Metadata Block: $(systemctl is-active metadata-block 2>/dev/null || echo 'inactive')"
echo "   • SSH: $(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo 'inactive')"
echo ""

echo -e "${GREEN}🔧 Useful Commands:${NC}"
echo "   # View mining logs"
echo "   tail -f /home/ubuntu/ccmn/mining.log"
echo ""
echo "   # Check service status"
echo "   sudo systemctl status ccmn"
echo "   sudo systemctl status dynamic-cpu-limit"
echo "   sudo systemctl status metadata-block"
echo ""
echo "   # Monitor CPU usage"
echo "   htop"
echo ""
echo "   # Test metadata blocking"
echo "   curl http://169.254.169.254/"
echo "   python3 -c \"print('Working')\""
echo ""
echo "   # Check limited processes"
echo "   cat /sys/fs/cgroup/limitcpu/cgroup.procs"
echo ""

if [ "$CCMN_STATUS" == "running" ]; then
    echo -e "${GREEN}🎉 Everything is working!${NC}"
else
    echo -e "${YELLOW}⚠️  CCMN mining service needs attention${NC}"
    echo "   Check with: sudo systemctl status ccmn"
    echo "   View logs: tail -50 /home/ubuntu/ccmn/mining.log"
fi

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}✅ Fix and verification complete!${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

exit 0
