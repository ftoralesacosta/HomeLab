#!/usr/bin/env bash
# Pre-power-off: make the boot env safe for a plain NAND boot, and verify
# the NAND rootfs write actually completed.
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1

echo '=== 1. full env dump (before) ==='
$SSH root@$IP 'fw_printenv'

echo
echo '=== 2. fix bootcmd: self-healing reset (no ubi_init, no copy attempt) ==='
$SSH root@$IP 'fw_setenv bootcmd "env default bootcmd ; saveenv ; run bootcmd" && echo SET && fw_printenv bootcmd'

echo
echo '=== 3. MTD layout ==='
$SSH root@$IP 'cat /proc/mtd'

echo
echo '=== 4. verify NAND rootfs write (attach UBI + volume sizes) ==='
$SSH root@$IP 'sh -s' <<'REMOTE'
if [ -d /sys/class/ubi/ubi0 ]; then
  echo "UBI already attached"
else
  command -v ubiattach >/dev/null || { echo "ubiattach not installed - skipping UBI check"; exit 0; }
  ubiattach -m 1 2>&1 | head -8
  sleep 2
fi
echo "--- UBI volumes ---"
for v in /sys/class/ubi/ubi_*_vol_*; do
  [ -e "$v" ] || continue
  echo "$(basename $v): type=$(cat $v/volume_type 2>/dev/null) used_bytes=$(cat $v/used_bytes 2>/dev/null)"
done
command -v ubinfo >/dev/null && ubinfo 2>/dev/null | head -40
REMOTE
echo
echo '=== RESULT GUIDE ==='
echo 'If a "fit" (rootfs) volume shows used_bytes ~ 36-42 MB  -> NAND write complete: power off, SW3=0:1, power on, then bash ~/bpi-r4-diag-nand.sh'
echo 'If no UBI attach / no fit volume -> do NOT switch to NAND yet; paste this whole output to the agent.'
