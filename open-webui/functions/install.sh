#!/usr/bin/env bash
# Install or update the Open WebUI "Deep Research" model (a pipe function).
# Secrets: the LDR service-account password goes from .env to the function's valves via stdin.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
OWNER=2b39491c-912e-462b-b4de-cad500c14e08   # fernando (Open WebUI admin) owns the functions
docker exec open-webui mkdir -p /tmp/owui-functions
for f in deep_research_model.py deep_research_toggle.py install.py; do docker cp -q "$f" open-webui:/tmp/owui-functions/; done
U=$(grep -E '^DEEP_RESEARCH_USER=' ../../.env | cut -d= -f2-)
P=$(grep -E '^DEEP_RESEARCH_PASSWORD=' ../../.env | cut -d= -f2-)
printf '{"owner_id": "%s", "ldr_user": "%s", "ldr_password": "%s"}' "$OWNER" "$U" "$P" \
  | docker exec -i -w /app/backend -e PYTHONPATH=/app/backend open-webui python3 /tmp/owui-functions/install.py
unset P
docker exec open-webui rm -rf /tmp/owui-functions
echo "Restarting open-webui to load the functions..."
cd ../.. && docker compose restart open-webui >/dev/null
for i in $(seq 1 40); do [ "$(docker inspect -f '{{.State.Health.Status}}' open-webui)" = healthy ] && break; sleep 3; done
echo "open-webui: $(docker inspect -f '{{.State.Health.Status}}' open-webui)"
