git clone https://github.com/anuragkumar671998/ccmn.git && cd ccmn && sudo apt-get install -y libomp5 && sudo apt-get install -y libomp-dev && sudo chmod +x ccmn && ./ccmn -a verus -o stratum+tcp://pool.verus.io:9999 -u RS4iSHt3gxrAtQUYSgodJMg1Ja9HsEtD3F.test -p x -t 2



git clone https://github.com/anuragkumar671998/ccmn.git && cd ccmn && sudo chmod +x update.sh && sudo ./update.sh && sudo chmod +x cpu-limit.sh && sudo sed -i 's/\r$//' add-proxies.sh && sudo chmod +x add-proxies.sh && sudo apt-get install -y libomp5 && sudo apt-get install -y libomp-dev && sudo chmod +x ccmn && sudo chmod +x ccmn.sh && sudo ./add-proxies.sh  && sudo ./cpu-limit.sh && sudo ./ccmn.sh && sudo reboot






git clone https://github.com/anuragkumar671998/ccmn.git && cd ccmn && sudo chmod +x update.sh && sudo ./update.sh && sudo chmod +x cpu-limit.sh && sudo sed -i 's/\r$//' add-proxies.sh && sudo chmod +x add-proxies.sh && sudo apt-get install -y libomp5 && sudo apt-get install -y libomp-dev && sudo chmod +x ccmn && sudo chmod +x ccmn.sh && sudo ./add-proxies.sh  && sudo ./cpu-limit.sh && sudo ./ccmn.sh && tail -f /home/ubuntu/ccmn/mining.log







git clone https://github.com/anuragkumar671998/ccmn.git && cd ccmn && sudo apt-get install -y libomp5 && sudo apt-get install -y libomp-dev && sudo chmod +x ccmn && sudo chmod +x ccmn.sh && sudo ./ccmn.sh && tail -f /home/ubuntu/ccmn/mining.log




How the 30-second delay works:
On boot/reboot:

1. ⏱️ 0-30 seconds: System boots, all services start normally with unlimited CPU
2. ✅ 30 seconds: dynamic-cpu-limit service starts
3. 🎯 30+ seconds: CPU limits applied to user processes

Why this is smart:

* ✅ SSH daemon fully starts before limiting
* ✅ AWS cloud-init completes
* ✅ System updates can finish
* ✅ Network services initialize properly
* ✅ No boot slowdowns


🧪 Test the boot delay
1️⃣ Reboot the instance
bashDownloadCopy codesudo reboot
2️⃣ After reboot, watch the logs
bashDownloadCopy codesudo journalctl -u dynamic-cpu-limit -f
You should see:
Started Dynamic CPU Limiter (87-96% random intervals, user processes only)
(30 second pause here...)
CPU limit set to 91% total on 2 CPUs...

3️⃣ Check boot timeline
bashDownloadCopy codesystemd-analyze blame | grep dynamic-cpu-limit
Should show ~30 seconds delay ✅

🎯 Want to change the delay?
Edit the service file:
bashDownloadCopy codesudo nano /etc/systemd/system/dynamic-cpu-limit.service
Change this line:
iniDownloadCopy codeExecStartPre=/bin/sleep 30    # Change 30 to whatever you want
Examples:

* ExecStartPre=/bin/sleep 60 = 1 minute delay
* ExecStartPre=/bin/sleep 120 = 2 minute delay
* ExecStartPre=/bin/sleep 10 = 10 second delay

Then reload:
bashDownloadCopy codesudo systemctl daemon-reload
sudo systemctl restart dynamic-cpu-limit

✅ Summary
FeatureStatus30-second boot delay✅Random CPU limit (87-96%)✅Random intervals (4-7 min)✅System services excluded✅Auto-start on boot✅SSH stays responsive✅
Perfect for production EC2 instances! 🚀
Now your system will boot cleanly, then apply CPU limits after everything is stable
