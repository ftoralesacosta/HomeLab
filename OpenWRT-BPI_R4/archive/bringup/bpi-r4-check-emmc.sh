#!/usr/bin/env bash
# Run from a NAND boot (SW3=0:1): does this board have eMMC, and what's on it?
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1

ok=0
for i in $(seq 1 36); do ping -c1 -W2 $IP >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
[ "$ok" = 1 ] || { echo "no ping - make sure SW3=0:1 (NAND boot) and power is on"; exit 1; }

$SSH root@$IP 'sh -s' <<'REMOTE'
echo '===== block devices ====='
ls /sys/block/
for b in /sys/block/mmcblk*; do
  [ -e "$b" ] || continue
  echo "$b: size=$(cat $b/size 2>/dev/null) sectors name=$(cat $b/device/name 2>/dev/null)"
done
echo
echo '===== fdisk -l ====='
fdisk -l 2>/dev/null | head -50
echo
echo '===== dmesg mmc/emmc ====='
dmesg | grep -iE 'mmc|emmc' | tail -20
echo
echo '===== current bootcmd (was the eMMC one-shot consumed?) ====='
fw_printenv bootcmd
echo
echo '===== confirm this is a NAND boot ====='
dmesg | grep -iE 'ubi0: attached|ubifs.*mounted' | head -3
REMOTE
