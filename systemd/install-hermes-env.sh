#!/usr/bin/env bash
# Run once:  sudo bash ~/HomeLab/systemd/install-hermes-env.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=/home/fernando/HomeLab
# 1) Hermes loads its secrets from ~/HomeLab/.env (via a root-only copy)
install -m 644 $D/systemd/hermes-env.service /etc/systemd/system/hermes-env.service
install -D -m 644 $D/systemd/hermes-gateway.service.d/homelab-env.conf /etc/systemd/system/hermes-gateway.service.d/homelab-env.conf
# 2) remove the old copies from Hermes's own .env (backup kept, root-only)
H=/var/lib/hermes/.hermes/.env
cp -p $H /root/hermes.env.bak-20261025
sed -i -E '/^(COREWEAVE_API_KEY|API_SERVER_ENABLED|API_SERVER_HOST|API_SERVER_PORT|API_SERVER_KEY|SEARXNG_URL)=/d' $H
# 3) your HomeLab files belong to you; .env readable only by you
chown fernando:fernando $D/.env $D/docker-compose.yml $D/searxng/settings.yml
chmod 600 $D/.env
chmod 644 $D/docker-compose.yml $D/searxng/settings.yml
# 4) hermes loses root-equivalent docker access and access to your group-readable files
gpasswd -d hermes docker  || true
gpasswd -d hermes fernando || true
# 5) apply
systemctl daemon-reload
systemctl restart hermes-gateway
sleep 3
systemctl is-active hermes-env hermes-gateway || true
id hermes
echo "Done."
