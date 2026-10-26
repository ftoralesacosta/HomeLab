#!/usr/bin/env bash
# Basic function test while booted from SD (safe; read-only checks + env check).
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"

command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1

$SSH root@$IP 'sh -s' <<'REMOTE'
echo '===== 1. system ====='
uname -a; uptime; echo
free -m | head -2; df -h / | tail -1
echo
echo '===== 2. bootcmd env (must be DEFAULT now - one-shot consumed) ====='
fw_printenv bootcmd
echo
echo '===== 3. network interfaces ====='
ip -o link show
echo
for i in $(ls /sys/class/net); do
  st=$(cat /sys/class/net/$i/operstate 2>/dev/null)
  ipa=$(ifstatus $i 2>/dev/null | grep -m1 ipAddress | awk '{print $2}')
  echo "  $i: state=$st ip=${ipa:-n/a}"
done
echo
echo '===== 4. LAN DHCP server (should be serving 192.168.1.0/24) ====='
grep -A6 "config interface 'lan'" /etc/config/network | head -8
logread 2>/dev/null | grep -iE 'dnsmasq|dhcp' | tail -5
echo
echo '===== 5. SFP port / ONU module info ====='
for i in $(ls /sys/class/net); do
  out=$(ethtool -m $i 2>/dev/null | head -6)
  [ -n "$out" ] && { echo "--- module on $i:"; echo "$out"; }
done
dmesg | grep -iE 'sfp|sfp+|link' | tail -10
echo
echo '===== 6. recent log (errors?) ====='
logread 2>/dev/null | tail -15
REMOTE
