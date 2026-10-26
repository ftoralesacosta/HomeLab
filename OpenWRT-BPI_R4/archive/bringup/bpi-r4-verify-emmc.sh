#!/usr/bin/env bash
# STAGE 3: verify OpenWrt is running from eMMC (SW3=1:0).
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"

command -v sshpass >/dev/null || sudo apt-get install -y sshpass

ok=0
for i in $(seq 1 36); do
  if ping -c1 -W2 $IP >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "NO PING. eMMC boot failed - check SW3 left DOWN / right UP (1:0); serial console next."; exit 1; }

ssh-keygen -R $IP >/dev/null 2>&1
echo '=== router status ==='
$SSH root@$IP 'uname -a; echo ---; cat /etc/openwrt_release 2>/dev/null; echo ---; echo "* boot device:"; df -h / 2>/dev/null | tail -1; echo ---; echo "* interfaces:"; for i in lan wan; do echo -n "  $i: "; ifstatus $i 2>/dev/null | grep -m1 ipAddress || echo n/a; done; echo ---; ip -o link show | awk -F": " "{print \$2, \$(NF)}"'
echo
echo '================ OPENWRT IS RUNNING ================'
echo 'Next: ONU programming (iSzo SFP stick in the SFP+ port) -'
echo 'tell the agent you are at this stage.'
