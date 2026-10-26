#!/usr/bin/env bash
# Detach + verbose re-attach of UBI to list volume names & sizes.
set -u
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass
ssh-keygen -R $IP >/dev/null 2>&1
$SSH root@$IP 'sh -s' <<'REMOTE'
command -v ubiattach >/dev/null || { echo "mtd-utils not installed"; exit 0; }
ubidetach -p ubi0 2>&1
sleep 2
ubiattach -m 1 -v 2>&1 | head -50
echo "--- after re-attach ---"
ls /sys/class/ubi/ 2>/dev/null
REMOTE
