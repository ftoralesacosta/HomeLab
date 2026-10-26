#!/usr/bin/env bash
# STAGE 1b (patient version): on SD boot, re-trigger SD->NAND copy,
# verify the NAND write completed via UBI stats, and demand a long soak.
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"

command -v sshpass >/dev/null || sudo apt-get install -y sshpass

wait_ssh() {  # $1 = max attempts (20s each), $2 = label
  local n=$1 label=$2
  for attempt in $(seq 1 $n); do
    ssh-keygen -R $IP >/dev/null 2>&1
    out=$($SSH root@$IP 'echo ALIVE; uname -a' 2>/dev/null)
    if echo "$out" | grep -q ALIVE; then
      echo "[$label] SSH OK (attempt $attempt):"
      echo "$out"
      return 0
    fi
    sleep 20
  done
  echo "[$label] SSH never came up."
  return 1
}

echo '=== 1. wait for SD boot (up to 10 min) ==='
wait_ssh 30 'SD boot' || { echo "NO SSH from SD boot - something is wrong with SD boot; serial console time."; exit 1; }

echo '=== 2. current boot info + UBI state ==='
$SSH root@$IP 'cat /proc/mtd; echo ---; ls /sys/class/ubi/ 2>/dev/null; for v in /sys/class/ubi/ubi_*_vol_*; do [ -e "$v" ] && echo "$v used=$(cat $v/used_bytes 2>/dev/null)"; done; echo ---; dmesg | grep -iE "ubi|nand" | tail -10'

echo '=== 3. re-trigger SD->NAND copy (one-shot) ==='
$SSH root@$IP 'fw_setenv bootcmd "env default bootcmd ; saveenv ; run ubi_init ; bootmenu 0" && fw_printenv bootcmd && echo TRIGGERED' || { echo "fw_setenv failed"; exit 1; }

echo '=== 4. reboot; copy takes SEVERAL MINUTES; waiting up to 20 min ==='
sleep 15
for i in $(seq 1 240); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then echo "ping OK at ~$((i*5))s"; break; fi
  sleep 5
done

echo '=== 5. wait for SSH (up to 20 min) + check UBI write completion ==='
done_flag=0
for attempt in $(seq 1 60); do
  ssh-keygen -R $IP >/dev/null 2>&1
  out=$($SSH root@$IP 'echo ALIVE; for v in /sys/class/ubi/ubi_*_vol_*; do [ -e "$v" ] && echo "ubi-vol used_bytes=$(cat $v/used_bytes 2>/dev/null)"; done; dmesg | grep -iE "ubi (attach|error)|ubiformat|copy" | tail -6' 2>/dev/null)
  if echo "$out" | grep -q ALIVE; then
    echo "SSH OK at ~$((15+attempt*20))s:"
    echo "$out"
    # expect the rootfs volume to be ~37-40 MB used
    if echo "$out" | grep -E 'used_bytes=(3[0-9][0-9]{6}|4[0-9][0-9]{6})' >/dev/null; then
      done_flag=1
    fi
    break
  fi
  sleep 20
done
[ "$done_flag" = 1 ] || echo "NOTE: UBI usage not clearly ~37-40MB yet - the write may still be running."

cat <<'NEXT'
DO NOT POWER OFF YET.
Give it a flat 15 more minutes (the SPI-NAND write is slow; ping/SSH being up
does NOT mean the write finished). After 15 min:
  1) Power OFF
  2) Remove SD card
  3) SW3 = 0:1 (left UP, right DOWN)
  4) Power on, wait 3 min
  5) Run:  bash ~/bpi-r4-diag-nand.sh
     If SSH works -> bash ~/bpi-r4-step2-nand2emmc.sh
NEXT
