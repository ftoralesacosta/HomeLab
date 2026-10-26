#!/usr/bin/env bash
# Run ONCE after the router is booting from its final media (eMMC preferred, NAND fine).
# - sets a root password (currently BLANK)
# - prints LAN/WAN/SFP status
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ok=0
for i in $(seq 1 36); do ping -c1 -W2 $IP >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
[ "$ok" = 1 ] || { echo "no ping at $IP"; exit 1; }

read -rsp "New root password for the BPI-R4: " P1; echo
read -rsp "Repeat: " P2; echo
[ -n "$P1" ] && [ "$P1" = "$P2" ] || { echo "refusing: empty or mismatched password"; exit 1; }

ssh-keygen -R $IP >/dev/null 2>&1
# OpenWrt busybox has no chpasswd; feed passwd via stdin (keeps the password off the command line)
printf '%s\n%s\n' "$P1" "$P1" | $SSH root@$IP 'passwd root' || { echo "password set FAILED"; exit 1; }
echo "password set. verifying login with new password..."
sshpass -p "$P1" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$IP 'echo LOGIN-OK; cat /etc/openwrt_release | grep DISTRIB_RELEASE' 2>/dev/null || { echo "verify login FAILED"; exit 1; }
ssh-keygen -R $IP >/dev/null 2>&1

echo
echo "=== router summary ==="
sshpass -p "$P1" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$IP 'sh -s' <<'REMOTE'
echo "* boot: $(dmesg | grep -m1 -oE '[a-z0-9_]+: mapped 1 uImage.FIT' | cut -d: -f1) (mmcblk0p5 = eMMC, ubiblock0_3 = NAND)"
echo "* lan:  $(ifstatus lan 2>/dev/null | grep -m1 ipAddress)"
echo "* wan:  $(ifstatus wan 2>/dev/null | grep -m1 proto) / $(ifstatus wan 2>/dev/null | grep -m1 ipAddress)"
echo "* sfp-lan carrier: $(cat /sys/class/net/sfp-lan/carrier 2>/dev/null)   sfp-wan carrier: $(cat /sys/class/net/sfp-wan/carrier 2>/dev/null)"
echo "* eth:  $(ip -o link show eth0 | awk -F': ' '{print $2}' )"
echo "* wifi: $(wifi status 2>/dev/null | head -3 | tr '\n' ' ')"
REMOTE
echo
echo "post-install done. Next:  bash ~/bpi-r4-onu-probe.sh"
