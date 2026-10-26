#!/usr/bin/env bash
# Run from NAND boot: inspect the eMMC boot regions + partition geometry.
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1
$SSH root@$IP 'sh -s' <<'REMOTE'
echo '===== eMMC partition geometry (sysfs) ====='
for p in /sys/block/mmcblk0/mmcblk0p*; do
  [ -e "$p" ] || continue
  echo "$(basename $p): start=$(cat $p/start 2>/dev/null) size=$(cat $p/size 2>/dev/null) sectors"
done
echo
echo '===== eMMC offset 0x0 (preloader region, first 128 bytes) ====='
dd if=/dev/mmcblk0 bs=1 count=128 2>/dev/null | od -A x -t x1z | head -8
echo
echo '===== eMMC offset 0x100000 (1 MiB, FIP candidate) ====='
dd if=/dev/mmcblk0 bs=1 skip=$((16#100000)) count=64 2>/dev/null | od -A x -t x1z | head -4
echo
echo '===== eMMC offset 0x200000 (2 MiB, GPT candidate) ====='
dd if=/dev/mmcblk0 bs=1 skip=$((16#200000)) count=16 2>/dev/null | od -A x -t x1z | head -2
echo
echo '===== full fw_printenv ====='
fw_printenv
REMOTE
