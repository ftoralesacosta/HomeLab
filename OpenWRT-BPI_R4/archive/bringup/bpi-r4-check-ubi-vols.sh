#!/usr/bin/env bash
# Quick: list UBI volumes with sizes (correct sysfs names: ubi0_0, ubi0_1, ...)
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1
$SSH root@$IP 'sh -s' <<'REMOTE'
echo "--- /sys/class/ubi ---"
ls /sys/class/ubi/ 2>/dev/null
echo "--- volume details ---"
for v in /sys/class/ubi/ubi[0-9]_*; do
  [ -e "$v" ] || continue
  t=$(cat "$v/volume_type" 2>/dev/null)
  [ "$t" = "data" ] && continue
  echo "$(basename $v): type=$t used_bytes=$(cat $v/used_bytes 2>/dev/null)"
done
echo "--- ubinfo ---"
ubinfo 2>/dev/null | sed -n '1,60p'
REMOTE
