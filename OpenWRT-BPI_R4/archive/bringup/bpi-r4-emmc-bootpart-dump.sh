#!/usr/bin/env bash
# Dump the eMMC BOOT partitions (where the preloader actually lives).
set -u
IP=192.168.1.1
OUT=~/bpi-r4-probe
mkdir -p "$OUT"
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1

$SSH root@$IP 'ls /sys/block/mmcblk0/' | tr ' ' '\n' | grep boot || echo 'no boot partitions listed'
for bp in mmcblk0boot0 mmcblk0boot1; do
  [ -b /dev/$bp ] || true
  $SSH root@$IP "dd if=/dev/$bp bs=512 count=8 2>/dev/null" > "$OUT/${bp}_head.raw" 2>/dev/null
  echo "$bp: $(wc -c < "$OUT/${bp}_head.raw") bytes"
done
echo done
