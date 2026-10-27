#!/usr/bin/env bash
# Make the server's Wi-Fi (Intel AX210, wlp130s0, 192.168.4.51) more reliable while it has no cable.
#   1. Wi-Fi power saving OFF (now and at every connect) + Intel "active" power scheme (after reboot)
#   2. Watchdog: if the router stops answering for ~3 min, restart the Wi-Fi (systemd timer)
# Run (over SSH inside tmux is fine; Wi-Fi drops ~10 s):   sudo bash ~/HomeLab/server/setup-wifi.sh
# Undo: restore /root/*.bak-* copies, rm /etc/modprobe.d/iwlmvm-power.conf, systemctl disable --now wifi-watchdog.timer
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
TS=$(date +%Y%m%d-%H%M)
IF=/etc/network/interfaces
cp -p $IF /root/interfaces.bak-$TS

# 1a. power save off at every connect (iw is not installed; iwconfig is)
grep -q "iwconfig wlp130s0 power off" $IF || \
  sed -i '/wpa-conf \/etc\/wpa_supplicant\/wpa_supplicant.conf/a\        post-up /sbin/iwconfig wlp130s0 power off || true' $IF
# 1b. Intel firmware power scheme: 1 = active (no power saving); applies after reboot / module reload
echo "options iwlmvm power_scheme=1" > /etc/modprobe.d/iwlmvm-power.conf

# 2. watchdog
cat > /usr/local/sbin/wifi-watchdog.sh <<'EOF'
#!/bin/sh
# Restart the Wi-Fi if the router (192.168.4.1) has not answered for 3 checks in a row.
F=/run/wifi-watchdog.fails
if ping -c2 -W3 192.168.4.1 >/dev/null 2>&1; then echo 0 > $F; exit 0; fi
n=$(( $(cat $F 2>/dev/null || echo 0) + 1 )); echo $n > $F
logger -t wifi-watchdog "router unreachable ($n/3)"
if [ $n -ge 3 ]; then
  logger -t wifi-watchdog "restarting wlp130s0"
  ifdown wlp130s0; sleep 2; ifup wlp130s0; echo 0 > $F
fi
EOF
chmod 755 /usr/local/sbin/wifi-watchdog.sh
cat > /etc/systemd/system/wifi-watchdog.service <<'EOF'
[Unit]
Description=Restart Wi-Fi if the router is unreachable
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wifi-watchdog.sh
EOF
cat > /etc/systemd/system/wifi-watchdog.timer <<'EOF'
[Unit]
Description=Check the Wi-Fi link every minute
[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now wifi-watchdog.timer

echo "applying (Wi-Fi drops ~10 s)..."
ifdown wlp130s0 || true; sleep 2; ifup wlp130s0
sleep 8
/sbin/iwconfig wlp130s0 2>/dev/null | grep -E "ESSID|Frequency|Power Management|Signal" | sed 's/  */ /g'
ping -c2 -W2 192.168.4.1 >/dev/null && echo "router: OK" || echo "router: FAIL"
ping -c2 -W2 1.1.1.1 >/dev/null && echo "internet: OK" || echo "internet: FAIL"
systemctl is-active wifi-watchdog.timer | sed 's/^/watchdog timer: /'
echo "Done. Backups: /root/*.bak-$TS"
