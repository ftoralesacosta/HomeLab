#!/usr/bin/env bash
# One-off (2026-11-09): save the Authelia gate for sabnzbd / qbittorrent / bazarr
# in NPM's database. The gate is already live (hot-patched into NPM's generated
# nginx files); this makes it survive NPM regenerating them.
#
#   bash ~/HomeLab/nginx-proxy-manager/apply-security-gates.sh
#
# Asks for the NPM admin password once (hidden). Flags keep each host's
# current settings (HTTP/2 off, websockets off, block-exploits as before).
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${NPM_ADMIN_PASSWORD:-}" ]; then
  read -rsp "NPM admin password: " NPM_ADMIN_PASSWORD; echo
  export NPM_ADMIN_PASSWORD
fi
trap 'unset NPM_ADMIN_PASSWORD' EXIT

echo "== sabnzbd";     ./add-host.sh sabnzbd.ftoralesacosta.me     sabnzbd:8080     --authelia --update --no-http2 --no-websocket --no-block-exploits
echo "== qbittorrent"; ./add-host.sh qbittorrent.ftoralesacosta.me vpn-gateway:8080 --authelia --update --no-http2 --no-websocket
echo "== bazarr";      ./add-host.sh bazarr.ftoralesacosta.me      bazarr:6767      --authelia --update --no-http2 --no-websocket --no-block-exploits

echo
echo "== check"
./add-host.sh --list | grep -E "sabnzbd|qbittorrent|bazarr" || true
for h in sabnzbd qbittorrent bazarr; do
  printf '%-12s ' "$h"
  curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}\n' "https://$h.ftoralesacosta.me/"
done
echo "Expected: 302 -> https://auth.ftoralesacosta.me/... for all three."
