#!/usr/bin/env bash
# Diagnose the NAND-boot state: ping stability + persistent SSH retries.
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"

echo '=== 1. ping stability (60s) ==='
up=0; down=0
for i in $(seq 1 12); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then up=$((up+1)); else down=$((down+1)); fi
  sleep 5
done
echo "up=$up down=$down  $( [ $down -gt 0 ] && echo '  <-- rebooting/flapping!' || echo '  (stable)' )"

echo '=== 2. SSH with retries (up to ~4 min) ==='
ssh-keygen -R $IP >/dev/null 2>&1
ok=0
for attempt in 1 2 3 4 5 6 7 8; do
  out=$($SSH root@$IP 'echo ALIVE; uptime; echo --- mtd:; cat /proc/mtd; echo --- ubi dmesg:; dmesg | grep -iE "ubi|nand" | tail -8' 2>&1)
  if echo "$out" | grep -q ALIVE; then
    ok=1; echo "SSH OK on attempt $attempt:"; echo "$out"; break
  fi
  echo "attempt $attempt failed: $(echo "$out" | head -1)"
  sleep 30
done
[ "$ok" = 1 ] || {
  echo
  echo 'SSH never connected. NAND rootfs is probably incomplete (powered off during the copy).'
  echo 'RECOVERY: set SW3 back to 1:1 (BOTH DOWN), re-insert the SD card, power on,'
  echo 'then run:  bash ~/bpi-r4-step1b-sd-rewrite-nand.sh'
  exit 1
}
echo
echo 'SSH is working - NAND looks alive. Proceed with:  bash ~/bpi-r4-step2-nand2emmc.sh'
