#!/usr/bin/env bash
# Single source of truth for the CoreWeave (W&B Inference) API key: ~/HomeLab/.env
#
#   1. Put the key in ~/HomeLab/.env:   COREWEAVE_API_KEY=...
#   2. Run:                             ~/HomeLab/scripts/sync-coreweave-key.sh
#
# What it does:
#   - checks the key against the API (GET /models)
#   - copies COREWEAVE_API_KEY + COREWEAVE_API_BASE into the two services that keep
#     their own env files (root/hermes-owned, so this uses sudo):
#       /opt/open-webui/.env               -> Open WebUI   (recreated with docker compose)
#       /var/lib/hermes/.hermes/.env       -> Hermes agent (systemctl restart hermes-gateway)
#   - Codex CLI and your shells read the key straight from ~/HomeLab/.env (see ~/.bashrc),
#     so they need no copy; open a new shell after changing the key.
set -euo pipefail

SRC="$HOME/HomeLab/.env"
OWUI_ENV=/opt/open-webui/.env
HERMES_ENV=/var/lib/hermes/.hermes/.env

get() { grep -m1 "^$1=" "$SRC" | cut -d= -f2- | sed -E "s/^[\"']//; s/[\"']$//"; }
KEY=$(get COREWEAVE_API_KEY || true)
BASE=$(get COREWEAVE_API_BASE || true)
BASE=${BASE:-https://api.inference.wandb.ai/v1}
[ -n "$KEY" ] || { echo "COREWEAVE_API_KEY is empty in $SRC"; exit 1; }

code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" "$BASE/models" || true)
echo "API check ($BASE/models): HTTP $code"
if [ "$code" != "200" ]; then
  read -r -p "Key did not return 200. Copy it anyway? [y/N] " a
  [ "$a" = "y" ] || exit 1
fi

# set_var FILE NAME VALUE  (replace or append, keeps owner/permissions)
set_var() {
  local f=$1 n=$2 v=$3
  if sudo grep -q "^$n=" "$f"; then
    sudo sed -i "s|^$n=.*|$n=$(printf '%s' "$v" | sed 's/[|&\\]/\\&/g')|" "$f"
  else
    printf '%s=%s\n' "$n" "$v" | sudo tee -a "$f" >/dev/null
  fi
}

echo "Updating $OWUI_ENV ..."
set_var "$OWUI_ENV" COREWEAVE_API_KEY "$KEY"
set_var "$OWUI_ENV" COREWEAVE_API_BASE "$BASE"
echo "Updating $HERMES_ENV ..."
set_var "$HERMES_ENV" COREWEAVE_API_KEY "$KEY"

echo "Restarting Open WebUI ..."
(cd /opt/open-webui && sudo docker compose up -d --force-recreate) 2>&1 | tail -2
echo "Restarting Hermes ..."
sudo systemctl restart hermes-gateway
sleep 3
systemctl is-active hermes-gateway
echo "Done. Open a new shell for Codex to pick up the key."
