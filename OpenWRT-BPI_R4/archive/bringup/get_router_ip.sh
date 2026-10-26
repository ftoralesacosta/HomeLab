#!/bin/bash
echo '=== 1. SWEEP 192.168.1.0/24 ==='
for i in $(seq 1 254); do (ping -c1 -W1 192.168.1.$i >/dev/null 2>&1) & done; wait
	sleep 1; ip neigh show to 192.168.1.0/24
	echo '=== 2. HOST INTERNET ==='
	curl -sI --max-time 10 https://downloads.openwrt.org/releases/ | head -1
	echo '=== 3. BPI-R4 OPENWRT IMAGES ==='
	curl -s --max-time 15 https://downloads.openwrt.org/releases/25.12.6/targets/rockchip/armv8/ | grep -oE 'href="[^"]*bpi-r4[^"]*"' | sed 's/	href="//;s/"//' | sort -u
