#!/bin/bash
echo '=== A. SNIFF 60s ==='
sudo timeout 60 tcpdump -i enx000ec67d6484 -e -n -c 100 2>&1 | head -60
echo '=== B. SUBNET SWEEP ==='
for base in 192.168.0 192.168.100 192.168.11 192.168.5 10.0.0 172.16.0; do
	sudo ip addr flush dev enx000ec67d6484 2>/dev/null
	sudo ip addr add ${base}.100/24 dev enx000ec67d6484
	sleep 1
	ping -c1 -W2 ${base}.1 >/dev/null 2>&1 && echo "ALIVE: ${base}.1"
done
sudo ip addr flush dev enx000ec67d6484; sudo ip addr add 192.168.1.100/24 dev enx000ec67d6484
echo '=== C. IMAGES 25.12.6 ==='
curl -s https://downloads.openwrt.org/releases/25.12.6/targets/rockchip/armv8/ -o /tmp/armv8.html
echo "bytes: $(wc -c < /tmp/armv8.html)  bananapi: $(grep -c bananapi /tmp/armv8.html)"
grep -oE '>[^<]*' /tmp/armv8.html | sed 's/^>//' | grep -viE '^/|^$' | head -40
echo '=== D. IMAGES 24.10.8 ==='
curl -s https://downloads.openwrt.org/releases/24.10.8/targets/rockchip/armv8/ | grep -oE '>[^<]*bpi-r4[^<]*' | sed 's/^>//' | sort -u
