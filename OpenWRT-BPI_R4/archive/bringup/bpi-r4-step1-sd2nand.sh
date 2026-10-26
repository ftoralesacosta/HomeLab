#!/usr/bin/env bash
# STAGE 1: board is booting from SD (SW3=1:1). Trigger SD -> NAND copy.
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"

command -v sshpass >/dev/null || sudo apt-get install -y sshpass

echo '=== waiting for the router (up to 5 min) ==='
ok=0
for i in $(seq 1 60); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then ok=1; echo "ping OK after ~$((i*5))s"; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "NO PING after 5 min. Check: SW3 both DOWN, SD inserted, power on. Serial console is the fallback."; exit 1; }

echo '=== ssh + trigger SD->NAND copy ==='
ssh-keygen -R $IP >/dev/null 2>&1
$SSH root@$IP 'uname -a; cat /etc/openwrt_release 2>/dev/null | head -2' || { echo "SSH failed"; exit 1; }
$SSH root@$IP 'fw_setenv bootcmd "env default bootcmd ; saveenv ; run ubi_init ; bootmenu 0" && echo TRIGGERED' || { echo "fw_setenv failed"; exit 1; }

echo '=== rebooting router; waiting for it back (up to 8 min) ==='
sleep 10
ok=0
for i in $(seq 1 96); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then ok=1; echo "ping OK after ~$((i*5))s"; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "NO PING after reboot. The SD->NAND copy can take a few minutes - wait longer, then re-run this script's ping loop manually (ping -c1 $IP)."; exit 1; }

ssh-keygen -R $IP >/dev/null 2>&1
echo '=== verify it is up ==='
$SSH root@$IP 'uname -a; echo ---; cat /etc/openwrt_release 2>/dev/null | head -2'
cat <<'NEXT'
STAGE 1 COMPLETE. PHYSICAL steps:
  1) Power OFF the BPI-R4
  2) Remove the SD card
  3) Set SW3 to 0:1  (LEFT switch UP, RIGHT switch DOWN) = boot from NAND
  4) Power on (wait ~1 min)
  5) Run:  bash ~/bpi-r4-step2-nand2emmc.sh
NEXT
