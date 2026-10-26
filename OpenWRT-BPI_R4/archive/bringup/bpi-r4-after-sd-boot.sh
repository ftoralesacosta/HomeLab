#!/usr/bin/env bash
# Run after the BPI-R4 has had ~2 minutes with the SD card in it.
IF=enx000ec67d6484
echo "link: $(cat /sys/class/net/$IF/operstate)"
echo '--- ping 192.168.1.1 ---'
ping -c 4 -W 2 192.168.1.1 2>&1 | tail -3
echo '--- quick arp sweep of 192.168.1.0/24 (10s) ---'
for i in $(seq 1 254); do (ping -c1 -W1 192.168.1.$i >/dev/null 2>&1) & done; wait
sleep 1; ip neigh show to 192.168.1.0/24 | grep -v INCOMPLETE || echo '(no live hosts found)'
echo '--- try ssh (if ping worked) ---'
timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=4 root@192.168.1.1 'echo SSH_OK; cat /etc/openwrt_release' 2>&1 | head -3
