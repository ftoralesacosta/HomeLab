#!/usr/bin/env bash
# Restore the eMMC U-Boot bootcmd from the NAND system (board booted with SW3 = 0:1).
# NAND OpenWrt: 192.168.1.1, root, blank password.
# Needs the server cable to a router LAN port with an address on 192.168.1.0/24:
#   sudo ip addr add 192.168.1.100/24 dev enp129s0
ip -4 addr | grep -q "inet 192.168.1." || { echo "No 192.168.1.x address. Run: sudo ip addr add 192.168.1.100/24 dev enp129s0"; exit 1; }
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"
echo "waiting for the NAND system at $IP ..."
for i in $(seq 1 40); do ping -c1 -W2 $IP >/dev/null 2>&1 && break; sleep 3; done
eval $SSH root@$IP sh -s <<'EOF'
dmesg | grep -m1 "mapped 1 uImage.FIT"
printf '/dev/mmcblk0p1 0x0 0x40000 0x40000 1\n/dev/mmcblk0p1 0x40000 0x40000 0x40000 1\n' > /tmp/emmc_env.config
echo "--- eMMC env before:"; fw_printenv -c /tmp/emmc_env.config bootcmd boot_nolos
fw_setenv -c /tmp/emmc_env.config bootcmd 'if pstore check ; then run boot_recovery ; else run boot_emmc ; fi'
echo "--- eMMC env after:"; fw_printenv -c /tmp/emmc_env.config bootcmd
EOF
echo
echo "Done. Now: power off, set SW3 back to 1:0 (A down, B up), power on."
