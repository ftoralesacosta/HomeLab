#!/usr/bin/env bash
# Talk to the iSzo/ODI GPON stick over SSH (admin/admin, legacy algorithms).
#   ~/HomeLab/OpenWRT-BPI_R4/scripts/stick.sh 'flash get GPON_SN'
# Default: stick at 192.168.2.1, reached through the BPI-R4 (192.168.4.1).
# Env overrides: STICK_IP, STICK_PW (default admin), STICK_JUMP ("" = direct, no hop)
IP=${STICK_IP:-192.168.2.1}
JUMP=${STICK_JUMP-root@192.168.4.1}
P=()
[ -n "$JUMP" ] && P=(-o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %h:%p $JUMP")
exec sshpass -p "${STICK_PW:-admin}" ssh "${P[@]}" \
	-o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+3des-cbc \
	-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	-o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive \
	admin@"$IP" "$@"
