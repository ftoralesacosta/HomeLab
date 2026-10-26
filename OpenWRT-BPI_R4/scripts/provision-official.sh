#!/usr/bin/env bash
# Provision a FRESH official OpenWrt on the BPI-R4 back to our working state:
# root password + SSH key, tools, stick workarounds (patched sfp.ko + gpon-stick service),
# helper scripts, staged (disabled) cutover config, LAN 192.168.1.254 + 192.168.2.254.
# Run on the debian server: bash ~/HomeLab/OpenWRT-BPI_R4/scripts/provision-official.sh
set -u
D=~/HomeLab/OpenWRT-BPI_R4; L=$D/local; B=$L/backup/restore
OLD=192.168.1.1; NEW=192.168.1.254
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
P() { sshpass -p '' ssh $O -o PreferredAuthentications=password,none -o PubkeyAuthentication=no root@$OLD "$@"; }
K() { ssh -o BatchMode=yes $O root@$1 "${@:2}"; }
say() { echo; echo "[$(date +%T)] === $* ==="; }

say "1. SSH key + root password (copied from the old image's backup)"
P "mkdir -p /etc/dropbear && cat > /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys" < $B/etc/dropbear/authorized_keys
ROOTLINE=$(grep '^root:' $B/etc/shadow)
printf '%s\n' "$ROOTLINE" | P 'read -r L; sed -i "s|^root:.*|$L|" /etc/shadow && grep -c "^root:\$1\|^root:\$5\|^root:\$6\|^root:\$y" /etc/shadow'
K $OLD "echo key-login-OK; cat /etc/openwrt_release | grep DESCRIPTION" || { echo "key login failed"; exit 1; }

say "2. packages"
K $OLD "apk update >/dev/null 2>&1; apk add ethtool curl tcpdump 2>&1 | tail -2; apk info luci >/dev/null 2>&1 && echo luci: present || echo luci: absent"

say "3. stick workarounds: patched sfp.ko + gpon-stick service + helper scripts"
KV=$(K $OLD "uname -r")
K $OLD "cat /lib/modules/$KV/sfp.ko" > $L/sfpko/sfp.ko.orig-$KV
python3 $D/sfp-patch/sfp_patch2.py $L/sfpko/sfp.ko.orig-$KV $L/sfpko/sfp.ko.patched-$KV || exit 1
K $OLD "cat > /lib/modules/$KV/sfp.ko" < $L/sfpko/sfp.ko.patched-$KV
K $OLD "md5sum /lib/modules/$KV/sfp.ko /rom/lib/modules/$KV/sfp.ko"
K $OLD "cat > /etc/init.d/gpon-stick && chmod +x /etc/init.d/gpon-stick && /etc/init.d/gpon-stick enable" < $D/router/gpon-stick
for s in wan-on-stick wan-revert cutover rollback; do K $OLD "cat > /root/$s.sh && chmod +x /root/$s.sh" < $D/router/$s.sh; done
K $OLD "grep -q gpon-stick /etc/sysupgrade.conf || printf '/etc/init.d/gpon-stick\n/root/\n/lib/modules/$KV/sfp.ko\n' >> /etc/sysupgrade.conf; tail -3 /etc/sysupgrade.conf"

say "4. staged config (port forwards OFF, Wi-Fi OFF, DHCP reservation, hostname/TZ)"
K $OLD sh -s < /tmp/r4_stage.sh
python3 - <<'EOF' | K $OLD sh -s
import re
s=open("/etc/wpa_supplicant/wpa_supplicant.conf").read()
ssid=re.search(r'ssid="(.*)"', s).group(1); psk=re.search(r'psk="(.*)"', s).group(1)
q=lambda v: "'" + v.replace("'", "'\\''") + "'"
for i in ("default_radio0","default_radio1"):
    print(f"uci set wireless.{i}.ssid={q(ssid)}; uci set wireless.{i}.encryption=psk2+ccmp; uci set wireless.{i}.key={q(psk)}")
print(f"uci set wireless.default_radio2.ssid={q(ssid)}; uci set wireless.default_radio2.encryption=sae; uci set wireless.default_radio2.key={q(psk)}")
print("for i in default_radio0 default_radio1 default_radio2; do uci set wireless.$i.disabled=1; done; uci commit wireless; echo WIFI_STAGED")
EOF

say "5. LAN -> 192.168.1.254/24 + 192.168.2.254/24 (router moves off .1)"
K $OLD "uci -q delete network.lan.ipaddr; uci add_list network.lan.ipaddr=192.168.1.254/24; uci add_list network.lan.ipaddr=192.168.2.254/24; uci commit network; (sleep 2; /etc/init.d/network reload) >/dev/null 2>&1 </dev/null &"
sleep 15
K $NEW "uci get network.lan.ipaddr; uci show firewall | grep -c 'fwd_.*enabled=.0.'; uci show wireless | grep -E 'ssid|disabled' | head -6" || { echo "router not reachable at $NEW"; exit 1; }

say "6. reboot to prove everything comes up by itself"
K $NEW "sync; reboot"
echo "rebooted at $(date +%T)"
