#!/bin/bash

# Service setup script for CCMN miner
# This creates a systemd service that runs your miner in the background

# Define the service file path
SERVICE_FILE="/etc/systemd/system/ccmn.service"

# Create the service file
sudo bash -c "cat > $SERVICE_FILE" << EOL
[Unit]
Description=Verus Coin Miner (CCMN)
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/ccmn
ExecStart=/home/ubuntu/ccmn/ccmn -a verus -o stratum+tcp://pool.verus.io:9999 -u RS4iSHt3gxrAtQUYSgodJMg1Ja9HsEtD3F.aws -p x -t 2
Restart=always
RestartSec=10
StandardOutput=file:/home/ubuntu/ccmn/mining.log
StandardError=file:/home/ubuntu/ccmn/mining-error.log

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable the service
sudo systemctl daemon-reload
sudo systemctl enable ccmn
sudo systemctl start ccmn

# Set permissions for log files
touch /home/ubuntu/ccmn/mining.log
touch /home/ubuntu/ccmn/mining-error.log
chmod 644 /home/ubuntu/ccmn/mining.log
chmod 644 /home/ubuntu/ccmn/mining-error.log

echo "CCMN service set up successfully!"
echo "Status: $(sudo systemctl is-active ccmn)"
echo "Logs: /home/ubuntu/ccmn/mining.log (standard) and /home/ubuntu/ccmn/mining-error.log (errors)"
echo "To check status: sudo systemctl status ccmn"
echo "To view logs: tail -f /home/ubuntu/ccmn/mining.log"