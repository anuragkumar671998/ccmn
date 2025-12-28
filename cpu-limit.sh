#!/bin/bash

###############################################################################
# Dynamic CPU Limiter Setup Script (All-in-One)
# Limits USER processes to 87-96% with random 4-7 minute intervals
# EXCLUDES system services for stability
# Auto-detects CPU count and installs as systemd service
###############################################################################

set -e

echo "=========================================="
echo "Dynamic CPU Limiter - Installation"
echo "User processes only (system services excluded)"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: Please run with sudo"
    exit 1
fi

###############################################################################
# Step 0: Update package lists
###############################################################################
echo "Updating package lists..."
apt-get update -qq
echo "✓ Package lists updated"

# Auto-detect number of CPUs
NUM_CPUS=$(nproc)
echo "✓ Detected $NUM_CPUS CPU(s)"

###############################################################################
# Step 1: Create the main control script
###############################################################################
echo "Creating control script..."

cat > /usr/local/bin/dynamic-cpu-limit.sh << 'SCRIPT_EOF'
#!/bin/bash

# Auto-detect number of CPUs
NUM_CPUS=$(nproc)

# Dynamic CPU limiter: 87-96% TOTAL (auto-scaled)
CGROUP_PATH="/sys/fs/cgroup/limitcpu"
MIN_CPU=87       # 87% total
MAX_CPU=96       # 96% total
MIN_INTERVAL=240 # 4 minutes
MAX_INTERVAL=420 # 7 minutes

# System services/users to EXCLUDE from limiting (always full CPU access)
EXCLUDE_USERS=("root" "systemd+" "systemd-resolve" "systemd-timesync" "systemd-network" "_apt")
EXCLUDE_PROCESSES=("sshd" "systemd" "journald" "rsyslogd" "cron" "dbus-daemon" "snapd" "unattended-upgr" "amazon-ssm-agen" "cloud-init")

mkdir -p "$CGROUP_PATH"

# Function to check if process should be excluded
should_exclude_pid() {
    local pid=$1
    
    # Get process info
    local proc_user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    local proc_cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
    
    # Check if user is in exclude list
    for user in "${EXCLUDE_USERS[@]}"; do
        if [[ "$proc_user" == "$user" ]]; then
            return 0  # Exclude
        fi
    done
    
    # Check if process name is in exclude list
    for proc in "${EXCLUDE_PROCESSES[@]}"; do
        if [[ "$proc_cmd" == *"$proc"* ]]; then
            return 0  # Exclude
        fi
    done
    
    return 1  # Don't exclude (apply limit)
}

while true; do
    RANDOM_PERCENT=$((MIN_CPU + RANDOM % (MAX_CPU - MIN_CPU + 1)))
    RANDOM_CPU=$((RANDOM_PERCENT * NUM_CPUS * 1000))
    
    echo "$RANDOM_CPU 100000" > "$CGROUP_PATH/cpu.max"
    
    # Only move non-system processes to limited group
    for pid in $(ps -e -o pid= 2>/dev/null); do
        if ! should_exclude_pid "$pid"; then
            echo "$pid" > "$CGROUP_PATH/cgroup.procs" 2>/dev/null
        fi
    done
    
    RANDOM_INTERVAL=$((MIN_INTERVAL + RANDOM % (MAX_INTERVAL - MIN_INTERVAL + 1)))
    
    logger "CPU limit set to ${RANDOM_PERCENT}% total on ${NUM_CPUS} CPUs (${RANDOM_CPU}/100000) for $RANDOM_INTERVAL seconds (system services excluded)"
    
    sleep "$RANDOM_INTERVAL"
done
SCRIPT_EOF

chmod +x /usr/local/bin/dynamic-cpu-limit.sh
echo "✓ Control script created at /usr/local/bin/dynamic-cpu-limit.sh"

###############################################################################
# Step 2: Create systemd service
###############################################################################
echo "Creating systemd service..."

cat > /etc/systemd/system/dynamic-cpu-limit.service << 'SERVICE_EOF'
[Unit]
Description=Dynamic CPU Limiter (87-96% random intervals, user processes only)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dynamic-cpu-limit.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "✓ Systemd service created"

###############################################################################
# Step 3: Enable and start the service
###############################################################################
echo "Enabling and starting service..."

systemctl daemon-reload
systemctl enable dynamic-cpu-limit.service
systemctl start dynamic-cpu-limit.service

echo "✓ Service started and enabled for boot"

###############################################################################
# Step 4: Verify installation
###############################################################################
echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Service Status:"
systemctl status dynamic-cpu-limit.service --no-pager -l
echo ""
echo "Current CPU Limit:"
cat /sys/fs/cgroup/limitcpu/cpu.max 2>/dev/null || echo "(Will be set within 4-7 minutes)"
echo ""
echo "=========================================="
echo "Excluded from CPU limits:"
echo "  - System users: root, systemd+, systemd-resolve, etc."
echo "  - Critical services: sshd, systemd, journald, cron, etc."
echo "  - AWS services: amazon-ssm-agent, cloud-init"
echo "=========================================="
echo ""
echo "Useful Commands:"
echo "=========================================="
echo "  View logs:        sudo journalctl -u dynamic-cpu-limit -f"
echo "  Check status:     sudo systemctl status dynamic-cpu-limit"
echo "  Stop service:     sudo systemctl stop dynamic-cpu-limit"
echo "  Restart service:  sudo systemctl restart dynamic-cpu-limit"
echo "  Disable service:  sudo systemctl disable dynamic-cpu-limit"
echo "  Remove limit:     echo 'max' | sudo tee /sys/fs/cgroup/limitcpu/cpu.max"
echo ""
echo "  Check which PIDs are limited:"
echo "    cat /sys/fs/cgroup/limitcpu/cgroup.procs"
echo ""
echo "  See limited processes:"
echo "    ps -p \$(cat /sys/fs/cgroup/limitcpu/cgroup.procs | tr '\\n' ',' | sed 's/,\$//') -o pid,user,comm"
echo "=========================================="
echo ""