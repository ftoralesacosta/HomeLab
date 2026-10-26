#!/usr/bin/env bash
# Add a user to Authelia (file backend) in one step.
#
#   ~/HomeLab/authelia/add-user.sh <username> <email> "<Display Name>" [group]
#   ~/HomeLab/authelia/add-user.sh jane jane@example.com "Jane Doe"            # friend: no group
#   ~/HomeLab/authelia/add-user.sh --dry-run jane jane@example.com "Jane Doe"  # show, change nothing
#
# The account gets a random password nobody knows; the user sets their own with "Reset password?".
# Never give friends the "admin" group.
set -euo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
[ $# -ge 3 ] || { sed -n '3,9p' "$0"; exit 1; }
U=$1; E=$(printf '%s' "$2" | tr 'A-Z' 'a-z'); N=$3; G=${4:-}
[[ $U =~ ^[a-z0-9._-]+$ ]] || { echo "username: lowercase letters, digits, . _ - only"; exit 1; }
[[ $E =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "invalid email"; exit 1; }
[ "$G" = admin ] && { read -r -p "Really give '$U' the admin group? [y/N] " a; [ "$a" = y ] || exit 1; }

D=$(cd "$(dirname "$0")" && pwd)
IMG=ghcr.io/authelia/authelia:4.39
# auth_file.yml may be root-owned (Authelia rewrites it) -> read/write it through a small container
RUNF() { docker run --rm -i -v "$D:/a" alpine:3 sh -c "$1"; }

if RUNF "grep -qE '^    $U:' /a/auth_file.yml"; then echo "user '$U' already exists"; exit 1; fi
if RUNF "grep -qiE '^ +email: \"?$E\"?\$' /a/auth_file.yml"; then echo "email '$E' already in use"; exit 1; fi

HASH=$(docker run --rm $IMG authelia crypto hash generate argon2 --password "$(openssl rand -hex 24)" | sed -n 's/^Digest: //p')
[[ $HASH == '$argon2id$'* ]] || { echo "hash generation failed"; exit 1; }
GROUPS_YAML="[]"; [ -n "$G" ] && GROUPS_YAML="[$G]"
NAME_ESC=${N//\\/\\\\}; NAME_ESC=${NAME_ESC//\"/\\\"}
ENTRY=$(printf '    %s:\n        password: "%s"\n        displayname: "%s"\n        email: %s\n        groups: %s\n        disabled: false\n' \
  "$U" "$HASH" "$NAME_ESC" "$E" "$GROUPS_YAML")

if [ $DRY = 1 ]; then echo "Would append to $D/auth_file.yml:"; printf '%s\n' "$ENTRY" | sed -E 's/(password: ).*/\1"<random argon2id hash>"/'; exit 0; fi

printf '%s\n' "$ENTRY" | RUNF "cp -p /a/auth_file.yml /tmp/b && cat >> /a/auth_file.yml"
# validate; on failure, show the error (the file is left as-is so you can inspect it)
if ! docker run --rm -e AUTHELIA_NOTIFIER_SMTP_PASSWORD=x -v "$D/configuration.yml:/config/configuration.yml:ro" \
     -v "$D/auth_file.yml:/config/auth_file.yml:ro" $IMG authelia validate-config --config /config/configuration.yml >/dev/null; then
  echo "Authelia config check FAILED - not restarting. Check the end of $D/auth_file.yml"; exit 1
fi
docker restart authelia >/dev/null && sleep 5
docker inspect -f '{{.State.Status}}' authelia | grep -q running || { echo "Authelia did not come back up!"; exit 1; }

cat <<EOF
Added '$U' ($N, $E). Authelia restarted.

Send them:
  Go to https://webui.ftoralesacosta.me and click "Continue with Authelia".
  Click "Reset password?" and enter $U (or $E). Open the email link within 30 minutes,
  choose a password, then log in. Accept the consent screen. You will see "pending"
  until I approve you.

Then approve them: Open WebUI -> Admin Panel -> Users -> role "pending" -> "user".
EOF
