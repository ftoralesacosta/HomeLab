#!/bin/bash
echo '=== 1. DHCP ON ENX ==='
sudo ip addr flush dev enx000ec67d6484
echo 'ip add done'
sudo dhclient -v -1 enx000ec67d6484 2>&1 | tail -15
echo 'dhclient done'
ip -br addr show enx000ec67d6484
echo '=== 2. RAW 25.12.6 ARMV8 INDEX ==='
curl -s https://downloads.openwrt.org/releases/25.12.6/targets/rockchip/armv8/ -o /tmp/armv8.html
wc -c /tmp/armv8.html
echo "bananapi mentions: $(grep -c bananapi /tmp/armv8.html)"
grep -oE '>[^<]*' /tmp/armv8.html | sed 's/^>//' | grep -iE 'bpi|img.gz' | head -30
echo '=== 3. FALLBACK: 24.10.8 ARMV8 INDEX ==='
curl -s https://downloads.openwrt.org/releases/24.10.8/targets/rockchip/armv8/ -o /tmp/armv8_2410.html
echo "bananapi mentions: $(grep -c bananapi /tmp/armv8_2410.html)"
grep -oE '>[^<]*bpi-r4[^<]*' /tmp/armv8_2410.html | sed 's/^>//' | sort -u
