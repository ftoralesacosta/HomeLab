#!/usr/bin/env bash
# After a power-on in a given SW3 switch state: report WHICH media booted.
# Usage:  bash ~/bpi-r4-probe-which-media.sh STATE_LABEL   (e.g. "D")
# Safe: read-only on the router. Appends one line to ~/bpi-r4-probe/matrix.csv
set -u
STATE="${1:-?}"
IP=192.168.1.1
CSV=~/bpi-r4-probe/matrix.csv
mkdir -p ~/bpi-r4-probe
[ -e "$CSV" ] || echo "state,result,rootfs,mmcblk0_dev,cmdline" > "$CSV"

SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass

echo "=== probe-which-media (state $STATE) ==="
ok=0
for i in $(seq 1 24); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then ok=1; echo "ping OK after ~$((i*5))s"; break; fi
  sleep 5
done
if [ "$ok" != 1 ]; then
  echo "RESULT: $STATE => DEAD or no IP (no ping in 2 min)"
  echo "$STATE,dead,-,-,-" >> "$CSV"
  exit 1
fi

ssh-keygen -R $IP >/dev/null 2>&1
RAW=$($SSH root@$IP 'sh -s' <<'REMOTE' 2>/dev/null
echo "KERNEL=$(uname -r)"
echo "CMDLINE= $(cat /proc/cmdline)"
echo "ROOTFS=$(awk '$2=="/" {print $1}' /proc/mounts)"
echo "MMC0DEV=$(cat /sys/block/mmcblk0/device/name 2>/dev/null || echo none)"
echo "MMC1DEV=$(cat /sys/block/mmcblk1/device/name 2>/dev/null || echo none)"
echo "UBI=$(dmesg 2>/dev/null | grep -m1 -o 'ubi0: attached [a-z0-9]*' || echo none)"
echo "SFP_LAN=$(cat /sys/class/net/sfp-lan/carrier 2>/dev/null || echo na) SFP_WAN=$(cat /sys/class/net/sfp-wan/carrier 2>/dev/null || echo na)"
echo "ETH0MAC=$(cat /sys/class/net/eth0/address 2>/dev/null)"
echo "REL=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null)"
REMOTE
) || RAW=""
[ -n "$RAW" ] || { echo "SSH failed - board has an IP but no SSH?"; echo "$STATE,sshfail,-,-,-" >> "$CSV"; exit 1; }
echo "$RAW" | sed 's/^/    /'

CMDLINE=$(echo "$RAW" | sed -n 's/^CMDLINE= //p')
ROOTFS=$(echo  "$RAW" | sed -n 's/^ROOTFS=//p')
MMC0DEV=$(echo "$RAW" | sed -n 's/^MMC0DEV=//p')
UBI=$(echo    "$RAW" | sed -n 's/^UBI=//p')

MEDIA=UNKNOWN
case "$CMDLINE" in
  *fit0*) MEDIA=NAND-SPI ;;
  *mmcblk0*) [ "$MMC0DEV" = "8GTF4R" ] && MEDIA=eMMC || MEDIA=SD-CARD ;;
esac
[ "$MEDIA" = "UNKNOWN" ] && [ -n "$UBI" ] && [ "$UBI" != "none" ] && [ "$ROOTFS" != *mmcblk* ] && MEDIA=NAND-SPI
echo
echo "RESULT: $STATE => ${MEDIA}"
echo "$STATE,${MEDIA},${ROOTFS},${MMC0DEV},${CMDLINE}" >> "$CSV"
echo "matrix so far: $(column -s, -t < "$CSV" 2>/dev/null || cat "$CSV")"
