#!/usr/bin/env bash
# NOT IN USE YET: run once the server is cabled to the router (BPI-R4 LAN port).
# Make the cable to the router (enp129s0 -> BPI-R4 lan1) the server's main connection.
#   Wired : 192.168.4.51 (same address as before: port forwards, SearXNG, docs unchanged)
#   Wi-Fi : 192.168.4.52, backup only (lower-priority default route), power saving off
# Run at the server's console (the Wi-Fi briefly drops):   sudo bash ~/HomeLab/server/setup-wired.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
F=/etc/network/interfaces
cp -p $F /root/interfaces.bak-$(date +%Y%m%d-%H%M)

cat > /etc/network/interfaces.d/enp129s0 <<'EOF'
# Wired link to the BPI-R4 router (lan1). Primary connection.
auto enp129s0
iface enp129s0 inet static
    address 192.168.4.51/22
    gateway 192.168.4.1
EOF

python3 - "$F" <<'EOF'
import sys, re
p = sys.argv[1]; s = open(p).read()
# old board's NIC (does not exist on this machine): comment out
s = s.replace("allow-hotplug enp1s0\niface enp1s0 inet static\n\taddress 192.168.1.10\n\tnetmask 255.255.255.0\n",
              "# (old board, not present)\n# allow-hotplug enp1s0\n# iface enp1s0 inet static\n#\taddress 192.168.1.10\n#\tnetmask 255.255.255.0\n")
old = re.search(r"# Wi-Fi configuration\nallow-hotplug wlp130s0\niface wlp130s0 inet static\n.*?(?=\n\S|\Z)", s, re.S)
assert old, "Wi-Fi stanza not found - nothing changed"
new = """# Wi-Fi configuration (BACKUP; the cable enp129s0 is primary)
allow-hotplug wlp130s0
iface wlp130s0 inet static
        address 192.168.4.52/22
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
        post-up iw dev wlp130s0 set power_save off || true
        post-up ip route add default via 192.168.4.1 dev wlp130s0 metric 600 || true
        pre-down ip route del default via 192.168.4.1 dev wlp130s0 metric 600 || true"""
s = s[:old.start()] + new + s[old.end():]
open(p, "w").write(s)
print("interfaces updated")
EOF

echo "switching over (Wi-Fi drops for a few seconds)..."
ifdown wlp130s0 || true
ip addr flush dev wlp130s0 || true
dhclient -r enp129s0 2>/dev/null || true; ip addr flush dev enp129s0 || true
ifup enp129s0
ifup wlp130s0 || echo "Wi-Fi backup did not come up (not critical)"
sleep 3
echo; ip -4 -br addr | grep -E "enp129s0|wlp130s0"
ip route | grep default
ping -c2 -W2 192.168.4.1 >/dev/null && echo "router: OK" || echo "router: FAIL"
ping -c2 -W2 1.1.1.1 >/dev/null && echo "internet: OK" || echo "internet: FAIL"
cat /sys/class/net/enp129s0/speed 2>/dev/null | sed 's/^/wired link speed (Mb\/s): /'
echo "Done. Backup of the old file: /root/interfaces.bak-*"
