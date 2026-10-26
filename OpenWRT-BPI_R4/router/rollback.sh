#!/bin/sh
# RUN ON THE BPI-R4. Undo cutover.sh AND wan-on-stick.sh: back to the pre-cutover bench
# state (LAN 192.168.1.254/24, Wi-Fi off, port forwards off, WAN on the RJ45/br-wan).
for f in wireless dhcp; do [ -f /etc/config/$f.pre-cutover ] && cp /etc/config/$f.pre-cutover /etc/config/$f; done
rm -f /etc/config/*.pre-cutover
if [ -f /etc/config/network.pre-stick ]; then
	/root/wan-revert.sh          # restores network + firewall (forwards disabled) and reloads
else
	uci -q delete network.lan.ipaddr; uci add_list network.lan.ipaddr='192.168.1.254/24'; uci commit network
	for s in fwd_ssh fwd_http fwd_https fwd_minecraft; do uci set firewall.$s.enabled='0'; done; uci commit firewall
	/etc/init.d/network reload; /etc/init.d/firewall reload
fi
for i in default_radio0 default_radio1 default_radio2; do uci set wireless.$i.disabled='1'; done
uci commit wireless
wifi reload; /etc/init.d/dnsmasq restart
echo "ROLLED BACK: router is back to the bench state (eero can take over again)"
