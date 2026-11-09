#!/usr/bin/env bash
# Host hardening that needs root. Idempotent: safe to re-run.
#   sudo bash ~/HomeLab/server/harden-host.sh
#
# 1. fail2ban: Debian 12 logs sshd to journald (no /var/log/auth.log), so the
#    stock sshd jail dies with "Have not found any log file". Use the systemd
#    backend and nftables bans; never ban the LAN.
# 2. unattended-upgrades: SECURITY updates only (Debian-Security), no automatic
#    reboots, no stable point releases, no backports/Docker repo packages.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

echo "== packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban python3-systemd nftables unattended-upgrades apt-listchanges >/dev/null
echo "ok"

echo "== fail2ban"
cat > /etc/fail2ban/jail.local <<'EOF'
# Managed by ~/HomeLab/server/harden-host.sh
[DEFAULT]
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
ignoreip = 127.0.0.1/8 ::1 192.168.4.0/22
findtime = 10m
maxretry = 5
bantime = 1h
# repeat offenders: 1h, 2h, 4h ... capped at 1 week
bantime.increment = true
bantime.maxtime = 1w

[sshd]
enabled = true
# key-only sshd: also count pre-auth disconnects / bad-key probes
mode = aggressive
EOF
fail2ban-client -t >/dev/null && echo "config ok"
systemctl enable -q fail2ban
systemctl restart fail2ban
sleep 3
fail2ban-client status sshd | sed -n '1,12p'

echo "== unattended-upgrades (security only, no auto-reboot)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-homelab <<'EOF'
// Managed by ~/HomeLab/server/harden-host.sh - overrides 50unattended-upgrades.
// Security fixes only; everything else (point releases, backports kernel,
// Docker) stays manual: sudo apt update && sudo apt upgrade
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
systemctl enable -q --now unattended-upgrades
echo "dry run (what it would install today):"
unattended-upgrade --dry-run -v 2>&1 | grep -E "Allowed origins|Packages that will be upgraded|No packages found" || true
echo
echo "Done. Logs: journalctl -u fail2ban ; /var/log/unattended-upgrades/"
