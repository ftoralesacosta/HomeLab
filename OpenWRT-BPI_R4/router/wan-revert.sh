#!/bin/sh
# RUN ON THE BPI-R4. Undo wan-on-stick.sh (stick port back into the LAN bridge, WAN back on br-wan).
set -e
[ -f /etc/config/network.pre-stick ] || { echo "no backup, nothing to revert"; exit 1; }
cp /etc/config/network.pre-stick /etc/config/network
cp /etc/config/firewall.pre-stick /etc/config/firewall
rm -f /etc/config/network.pre-stick /etc/config/firewall.pre-stick
/etc/init.d/network reload; /etc/init.d/firewall reload
echo "WAN reverted to br-lan/br-wan defaults"
