#!/usr/bin/env bash
# Add a user to Authelia (file backend) in one step.
#
#   ~/HomeLab/authelia/add-user.sh <username> <email> "<Display Name>" [group]
#   ~/HomeLab/authelia/add-user.sh jane jane@example.com "Jane Doe" friends    # Open WebUI only
#   ~/HomeLab/authelia/add-user.sh --dry-run jane jane@example.com "Jane Doe"  # show, change nothing
#
# Groups: admin | family (media apps + WebUI) | friends (WebUI only). No group = portal only.
# The account gets a random password nobody knows; the user sets their own with "Reset password?".
# No restart needed: Authelia watches users/auth_file.yml and reloads it.
set -euo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
[ $# -ge 3 ] || { sed -n '3,10p' "$0"; exit 1; }
U=$1; E=$(printf '%s' "$2" | tr 'A-Z' 'a-z'); N=$3; G=${4:-}
[[ $U =~ ^[a-z0-9._-]+$ ]] || { echo "username: lowercase letters, digits, . _ - only"; exit 1; }
[[ $E =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "invalid email"; exit 1; }
[ -z "$G" ] || [[ $G =~ ^[a-z0-9._-]+$ ]] || { echo "invalid group"; exit 1; }
[ "$G" = admin ] && { read -r -p "Really give '$U' the admin group? [y/N] " a; [ "$a" = y ] || exit 1; }

F="$(cd "$(dirname "$0")" && pwd)/users/auth_file.yml"
IMG=ghcr.io/authelia/authelia:4.39
HASH=$(docker run --rm $IMG authelia crypto hash generate argon2 --password "$(openssl rand -hex 24)" | sed -n 's/^Digest: //p')
[[ $HASH == '$argon2id$'* ]] || { echo "hash generation failed"; exit 1; }

U="$U" E="$E" N="$N" G="$G" H="$HASH" F="$F" DRY="$DRY" python3 - <<'EOF'
import json, os, sys, tempfile, yaml
u, e, n, g, h, f = (os.environ[k] for k in "UENGHF")
text = open(f).read()
users = yaml.safe_load(text)["users"]
if u in users: sys.exit(f"user '{u}' already exists")
if e in {str(v.get("email", "")).lower() for v in users.values()}: sys.exit(f"email '{e}' already in use")
groups = f"[{g}]" if g else "[]"
entry = (f"    {u}:\n        password: \"{h}\"\n        displayname: {json.dumps(n)}\n"
         f"        email: {e}\n        groups: {groups}\n        disabled: false\n")
if os.environ["DRY"] == "1":
    print("Would append:\n" + entry.replace(h, "<random argon2id hash>")); sys.exit(0)
new = (text if text.endswith("\n") else text + "\n") + entry
assert yaml.safe_load(new)["users"][u]["email"] == e
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".auth_file.")
with os.fdopen(fd, "w") as fh:
    fh.write(new)
os.chmod(tmp, 0o600)
os.replace(tmp, f)
EOF
[ $DRY = 1 ] && exit 0

cat <<EOF
Added '$U' ($N, $E, groups: [${G}]). Authelia reloads the users file by itself.

Send them:
  Go to https://webui.ftoralesacosta.me and click "Continue with Authelia".
  Click "Reset password?" and enter $U (or $E). Open the email link within 30 minutes,
  choose a password, then log in. Accept the consent screen. You will see "pending"
  until I approve you.

Then approve them: Open WebUI -> Admin Panel -> Users -> role "pending" -> "user".
EOF
