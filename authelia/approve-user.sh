#!/usr/bin/env bash
# Approve a pending signup: move the user from [pending] to a real group.
#
#   ~/HomeLab/authelia/approve-user.sh <username> [group]
#   approve-user.sh bonnie             # group: family
#   approve-user.sh bonnie friends     # Open WebUI only (no media apps)
#
# No restart needed: Authelia watches users/auth_file.yml and reloads it.
set -euo pipefail
[ $# -ge 1 ] || { sed -n '3,8p' "$0"; exit 1; }
U=$1; G=${2:-family}
[[ $U =~ ^[a-z0-9._-]+$ ]] || { echo "invalid username"; exit 1; }
[[ $G =~ ^[a-z0-9._-]+$ ]] || { echo "invalid group"; exit 1; }
[ "$G" = admin ] && { read -r -p "Really give '$U' the admin group? [y/N] " a; [ "$a" = y ] || exit 1; }

F="$(cd "$(dirname "$0")" && pwd)/users/auth_file.yml"
U="$U" G="$G" F="$F" python3 - <<'EOF'
import os, re, sys, tempfile, yaml
u, g, f = os.environ["U"], os.environ["G"], os.environ["F"]
text = open(f).read()
users = yaml.safe_load(text)["users"]
if u not in users or "pending" not in (users[u].get("groups") or []):
    sys.exit(f"'{u}' not found or not pending")
# Edit only that user's flow-style "groups: [pending]" line (signup writes it that way).
lines, out, inside = text.splitlines(keepends=True), [], False
for line in lines:
    if re.match(r"^    \S.*:\s*$", line):
        inside = line.strip() == f"{u}:"
    if inside and re.match(r"^\s+groups: \[pending\]\s*$", line):
        line = re.sub(r"\[pending\]", f"[{g}]", line)
    out.append(line)
new = "".join(out)
assert yaml.safe_load(new)["users"][u]["groups"] == [g], "edit failed"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".auth_file.")
with os.fdopen(fd, "w") as h:
    h.write(new)
os.chmod(tmp, 0o600)
os.replace(tmp, f)
EOF
sleep 3
if docker logs --since 10s authelia 2>&1 | grep -qiE 'level=(error|fatal)'; then
  echo "WARNING: Authelia logged an error after the reload:"; docker logs --since 10s authelia 2>&1 | tail -5
fi
echo "Approved '$U' (groups: [$G]). Authelia reloads the users file by itself."
echo "They can now log in to Open WebUI with 'Continue with Authelia' (no WebUI approval needed)."
