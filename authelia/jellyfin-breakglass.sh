#!/usr/bin/env bash
# Break-glass: switch a Jellyfin user back to the LOCAL (Default) password provider.
#
#   ~/HomeLab/authelia/jellyfin-breakglass.sh            # fernando (default)
#   ~/HomeLab/authelia/jellyfin-breakglass.sh someuser   # any user
#   ~/HomeLab/authelia/jellyfin-breakglass.sh --dry-run  # show what would happen
#
# Use when Authelia is DOWN and nobody can log into Jellyfin (SSO and the
# Authelia plugin both depend on it). Requires the pre-pulled python:3.12-alpine
# image and docker group access. Jellyfin is stopped briefly; the DB is backed
# up first.
set -euo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
U=${1:-fernando}
DBDIR=/home/fernando/.volumes/jellyfin/config/data
DB="$DBDIR/jellyfin.db"
DEFAULTPROV='Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider'

CUR=$(python3 -c "
import sqlite3
row = sqlite3.connect('file:$DB?mode=ro', uri=True).execute(
    'select AuthenticationProviderId from Users where Username = ?', ('$U',)).fetchone()
print(row[0] if row else 'NO_SUCH_USER')")
[ "$CUR" = "NO_SUCH_USER" ] && { echo "no Jellyfin user called '$U'"; exit 1; }
if [ "$CUR" = "$DEFAULTPROV" ]; then
  echo "'$U' is already on the Default provider - sign in with the local Jellyfin password."; exit 0
fi
echo "current provider for $U: $CUR"
if [ $DRY = 1 ]; then
  echo "DRY-RUN: would stop jellyfin, back up jellyfin.db*, set provider to Default, start jellyfin."
  exit 0
fi

BK="$HOME/HomeLab/backups/pre-breakglass-$(date +%Y%m%d-%H%M)"
mkdir -p "$BK"
docker stop jellyfin
docker run --rm -e U="$U" -e P="$DEFAULTPROV" -e UIDG="$(id -u):$(id -g)" \
  -v "$DBDIR":/db -v "$BK":/bk python:3.12-alpine python3 - <<'EOF'
import glob, os, shutil, sqlite3
u, p = os.environ['U'], os.environ['P']
uid, gid = map(int, os.environ['UIDG'].split(':'))
for f in glob.glob('/db/jellyfin.db*'):
    shutil.copy2(f, '/bk/' + os.path.basename(f))
con = sqlite3.connect('/db/jellyfin.db')
con.execute('update Users set AuthenticationProviderId = ? where Username = ?', (p, u))
con.commit()
row = con.execute('select Username, AuthenticationProviderId from Users where Username = ?',
                  (u,)).fetchone()
con.close()
print('provider is now:', row[1])
for f in os.listdir('/bk'):
    os.chown(os.path.join('/bk', f), uid, gid)
EOF
docker start jellyfin
sleep 10
docker inspect --format 'jellyfin: {{.State.Status}}' jellyfin
cat <<MSG

DONE. Jellyfin login for '$U' is back on the LOCAL password.
Sign in with your OLD Jellyfin password (the local one, NOT your Authelia password).
When Authelia is healthy again: Dashboard -> Users -> $U ->
Authentication Provider -> switch back to 'Authelia-Authentication'.
Database backup: $BK
MSG