#!/bin/sh
# RUN ON THE BPI-R4. Moves the GPON stick port (sfp-lan) out of the LAN bridge and makes
# it the WAN. Usage: wan-on-stick.sh [VID]   (no VID = untagged)
# Also adds 192.168.2.254/24 on the stick port so the LAN can reach the stick's web UI
# at 192.168.2.1 (masqueraded via the wan zone). Undo: wan-revert.sh
set -e
VID="$1"
[ -f /etc/config/network.pre-stick ] || cp /etc/config/network /etc/config/network.pre-stick
[ -f /etc/config/firewall.pre-stick ] || cp /etc/config/firewall /etc/config/firewall.pre-stick

BR=$(uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name='br-lan'$/\1/p")
uci -q del_list network.$BR.ports='sfp-lan' || true
uci -q del_list network.lan.ipaddr='192.168.2.254/24' || true   # moves to the onu interface below

DEV=sfp-lan; [ -n "$VID" ] && DEV="sfp-lan.$VID"
uci set network.wan.device="$DEV"
uci set network.wan6.device="$DEV"

uci -q delete network.onu || true
uci set network.onu=interface
uci set network.onu.proto='static'
uci set network.onu.device='sfp-lan'
uci set network.onu.ipaddr='192.168.2.254/24'
uci set network.onu.defaultroute='0'

WZ=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p")
uci -q del_list firewall.$WZ.network='onu' || true
uci add_list firewall.$WZ.network='onu'

uci commit network; uci commit firewall
/etc/init.d/network reload; /etc/init.d/firewall reload
echo "WAN now on $DEV (stick mgmt via 192.168.2.254 -> 192.168.2.1)"
