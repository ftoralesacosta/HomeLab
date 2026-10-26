#!/usr/bin/env bash
# EMERGENCY UNDO after a cutover that didn't work. Run on the debian server:
#     bash ~/HomeLab/OpenWRT-BPI_R4/scripts/rollback-all.sh
# Resets the BPI-R4 (LAN 192.168.4.1, or 192.168.1.254 over the server cable) to the bench state, then tells
# you how to bring the eero back.
R() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o LogLevel=ERROR -o ConnectTimeout=6 root@$RIP "$@"; }
RIP=192.168.4.1; ping -c1 -W2 $RIP >/dev/null 2>&1 || RIP=192.168.1.254
echo "resetting the BPI-R4..."
if R /root/rollback.sh; then echo "router reset OK"; else
	echo "could not reach the router — skip it, just do the steps below"; fi
echo
echo "##############################################################"
echo "##  1) move the fiber from the stick BACK to the Nokia ONT"
echo "##  2) plug the eero's power back in (leave the BPI-R4 WAN cable unplugged)"
echo "##  3) wait ~3-5 min: your Wi-Fi and internet come back via the eero"
echo "##############################################################"
read -r -p "Press Enter when done (waits for internet)... " _ </dev/tty || true
for i in $(seq 1 60); do ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && { echo "internet back after ~$((i*5))s"; exit 0; }; sleep 5; done
echo "still offline: power-cycle the eero and the Nokia ONT, wait 5 more minutes."
