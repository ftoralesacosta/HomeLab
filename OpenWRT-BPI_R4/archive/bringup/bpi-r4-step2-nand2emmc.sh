#!/usr/bin/env bash
# STAGE 2: board boots from NAND (SW3=0:1). Trigger NAND -> eMMC copy.
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
[ "$ok" = 1 ] || { echo "NO PING after 5 min. Check: SW3 left UP / right DOWN (0:1), power on, no SD needed. Serial fallback."; exit 1; }

echo '=== ssh + trigger NAND->eMMC copy ==='
ssh-keygen -R $IP >/dev/null 2>&1
$SSH root@$IP 'uname -a; cat /etc/openwrt_release 2>/dev/null | head -2' || { echo "SSH failed"; exit 1; }
$SSH root@$IP 'fw_setenv bootcmd "env default bootcmd ; saveenv ; run emmc_init ; bootmenu 0" && echo TRIGGERED' || { echo "fw_setenv failed"; exit 1; }

echo '=== rebooting; waiting for it back (up to 8 min) ==='
sleep 10
ok=0
for i in $(seq 1 96); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then ok=1; echo "ping OK after ~$((i*5))s"; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "NO PING after reboot - the eMMC copy takes a while; wait a few more minutes then check: ping -c1 $IP"; exit 1; }

ssh-keygen -R $IP >/dev/null 2>&1
echo '=== verify ==='
$SSH root@$IP 'uname -a; echo ---; cat /etc/openwrt_release 2>/dev/null | head -2'
cat <<'NEXT'
STAGE 2 COMPLETE. PHYSICAL steps:
  1) Power OFF the BPI-R4
  2) Set SW3 to 1:0  (LEFT switch DOWN, RIGHT switch UP) = boot from eMMC
  3) Power on (wait ~1 min)
  4) Run:  bash ~/bpi-r4-verify-emmc.sh
NEXT
