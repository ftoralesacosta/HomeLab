#!/bin/sh
# RUN ON THE BPI-R4 (after wan-on-stick.sh, with the Verizon WAN up).
# Final cutover: LAN 192.168.4.1/22 (eero's subnet; 192.168.1.254/24 kept as a
# secondary address for the server's wired bench link), Wi-Fi on (eero SSID/password),
# homelab port forwards on. Undo: /root/rollback.sh
set -e
for f in network firewall wireless dhcp; do cp /etc/config/$f /etc/config/$f.pre-cutover; done

uci -q delete network.lan.ipaddr
uci add_list network.lan.ipaddr='192.168.4.1/22'     # first = DHCP pool subnet
uci add_list network.lan.ipaddr='192.168.1.254/24'   # server bench link (enp129s0)

for s in fwd_ssh fwd_http fwd_https fwd_minecraft; do uci set firewall.$s.enabled='1'; done
for i in default_radio0 default_radio1 default_radio2; do uci set wireless.$i.disabled='0'; done

uci commit network; uci commit firewall; uci commit wireless
/etc/init.d/network reload
/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart
wifi reload
echo "CUTOVER APPLIED: LAN 192.168.4.1/22 (+192.168.1.254), Wi-Fi on, port forwards on"
