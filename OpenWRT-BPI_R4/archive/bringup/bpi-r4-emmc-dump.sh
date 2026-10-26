#!/usr/bin/env bash
# Dump key eMMC regions as raw bytes over the SSH channel (binary-safe).
set -u
IP=192.168.1.1
OUT=~/bpi-r4-probe
mkdir -p "$OUT"
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1

for spec in "0:2" "1:1" "8192:2" "13312:2" "34:1" "131072:1"; do
  s=${spec%%:*}; c=${spec##*:}
  $SSH root@$IP "dd if=/dev/mmcblk0 bs=512 skip=$s count=$c 2>/dev/null" > "$OUT/emmc_lba${s}.raw"
  sz=$(wc -c < "$OUT/emmc_lba${s}.raw")
  echo "LBA $s (count $c): $sz bytes"
done
echo dump-done
