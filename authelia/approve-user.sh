#!/usr/bin/env bash
# Approve a pending signup: flip the Authelia group and restart.
#
#   ~/HomeLab/authelia/approve-user.sh <username> [group]
#   approve-user.sh bonnie             # group: family
#   approve-user.sh bonnie friends     # any other group
#   approve-user.sh bonnie ""          # no group (portal only, per access_control)
#
# Remember the WebUI half: WebUI -> Admin Panel -> Users -> role "pending" -> "user".
set -euo pipefail
[ $# -ge 1 ] || { sed -n '3,9p' "$0"; exit 1; }
U=$1; G=${2:-family}
[[ $U =~ ^[a-z0-9._-]+$ ]] || { echo "invalid username"; exit 1; }
if [ -n "$G" ] && ! [[ $G =~ ^[a-z0-9._-]+$ ]]; then echo "invalid group"; exit 1; fi

D=$(cd "$(dirname "$0")" && pwd)
RUNF() { docker run --rm -i -v "$D:/a" alpine:3 sh -c "$1"; }

# user must exist and still be pending
RUNF "awk -v u='    $U:' '\$0==u{f=1} f&&/groups: \[pending\]/{p=1} END{exit p?0:1}' /a/auth_file.yml" \
  || { echo "'$U' not found or not pending"; exit 1; }

GSPEC=$([ -n "$G" ] && printf '[%s]' "$G" || printf '[]')
RUNF "awk -v u='    $U:' -v g='groups: $GSPEC' '
  \$0==u {f=1}
  f && /^    [a-z0-9._-]+:/ && \$0 != u {f=0}
  f && /groups: \[pending\]/ {sub(/groups: \[pending\]/, g)}
  {print}' /a/auth_file.yml > /tmp/n && cat /tmp/n > /a/auth_file.yml && rm /tmp/n"

# validate; on failure, show the error (the file is left as-is so you can inspect it)
if ! docker run --rm -e AUTHELIA_NOTIFIER_SMTP_PASSWORD=x -v "$D/configuration.yml:/config/configuration.yml:ro" \
     -v "$D/auth_file.yml:/config/auth_file.yml:ro" ghcr.io/authelia/authelia:4.39 \
     authelia validate-config --config /config/configuration.yml >/dev/null; then
  echo "Authelia config check FAILED - not restarting. Check the end of $D/auth_file.yml"; exit 1
fi
docker restart authelia >/dev/null && sleep 5
docker inspect -f '{{.State.Status}}' authelia | grep -q running || { echo "Authelia did not come back up!"; exit 1; }

echo "Approved '$U' (groups: $GSPEC). Authelia restarted."
echo "They can now log in at https://auth.ftoralesacosta.me and use the apps their group is allowed."
if [ "$G" = family ]; then
  echo "WebUI half: Open WebUI -> Admin Panel -> Users -> role 'pending' -> 'user'."
fi