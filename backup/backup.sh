#!/usr/bin/env bash
# =============================================================================
# Nightly homelab backup (cron 03:30). Plain bash + restic. Nothing runs between backups.
#
#  1. STAGE   consistent copies of each app's data into /mnt/data/backups/staging
#             (each container is paused for the few seconds its folder is copied, so no
#             SQLite database is caught mid-write; regenerable caches are skipped)
#  2. EXPORT  readable JSON: Sonarr series / Radarr movies ("re-download list"), quality
#             profiles, indexers, download clients; Actual rules/categories/payees/accounts
#  3. BACKUP  restic snapshot of staging + ~/HomeLab (incl. .env and other gitignored secrets)
#             to TWO encrypted repositories:
#               - local:   /mnt/data/backups/restic   (second NVMe, fast restores)
#               - offsite: Google Drive  homelab-backups/restic  (via rclone)
#  4. PRUNE   keep 7 daily, 4 weekly, 12 monthly snapshots;  Sundays: integrity check
#
# Needs in ~/HomeLab/.env:  RESTIC_PASSWORD  (+ RCLONE_CONFIG_GDRIVE_* for the offsite copy)
# Usage:  backup.sh            full run
#         backup.sh --stage    only steps 1-2 (no restic)
#         backup.sh --snapshots   list snapshots in both repos
# Log: ~/HomeLab/backup/logs/backup.log   Restore: see ~/HomeLab/backup/README.md
# =============================================================================
set -uo pipefail
HL=/home/fernando/HomeLab
V=/home/fernando/.volumes
B=/mnt/data/backups
STAGE=$B/staging
LOCAL_REPO=/repo-local
GDRIVE_REPO=rclone:gdrive:homelab-backups/restic
IMG=homelab-backup:restic
LOGDIR=$HL/backup/logs; LOG=$LOGDIR/backup.log
mkdir -p "$LOGDIR"
FAIL=0
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

PAUSED=()
unpause_all() { for c in "${PAUSED[@]}"; do docker unpause "$c" >/dev/null 2>&1; done; PAUSED=(); }
cleanup() { unpause_all; rm -f "${ENVF:-}"; }
trap cleanup EXIT

# ---------- 1. stage ----------
# stage <name> <container-to-pause or ""> <source dir> [exclude patterns relative to source, e.g. ./log]
stage() {
  local name=$1 ctr=$2 src=$3; shift 3
  local ex=() e
  for e in "$@"; do ex+=(--exclude="$e"); done
  if [ ! -d "$src" ] && ! docker run --rm -v "$(dirname "$src")":/p:ro alpine:3 test -d "/p/$(basename "$src")"; then
    log "WARN  $name: $src not found, skipped"; return; fi
  if [ -n "$ctr" ] && docker ps --format '{{.Names}}' | grep -qx "$ctr"; then docker pause "$ctr" >/dev/null && PAUSED+=("$ctr"); fi
  docker run --rm -v "$src":/src:ro -v "$STAGE":/stage debian:stable-slim bash -c \
    "rm -rf /stage/$name && mkdir -p /stage/$name && tar -C /src ${ex[*]} -cf - . | tar -C /stage/$name -xf -"
  local rc=$?
  unpause_all
  if [ $rc = 0 ]; then log "staged $name"; else log "ERROR staging $name (rc $rc)"; FAIL=1; fi
}

do_stage() {
  docker run --rm -v /mnt/data:/m alpine:3 sh -c "mkdir -p /m/backups/staging/exports /m/backups/restic /m/backups/restic-cache && chown 1000:1000 /m/backups /m/backups/staging /m/backups/staging/exports"
  log "=== stage"
  stage actual-budget  actual-budget   "$V/actual-budget/data"
  stage sonarr         sonarr          "$V/sonarr/config"      ./logs ./logs.db ./logs.db-shm ./logs.db-wal ./MediaCover
  stage radarr         radarr          "$V/radarr/config"      ./logs ./logs.db ./logs.db-shm ./logs.db-wal ./MediaCover
  stage prowlarr       prowlarr        "$V/prowlarr/config"    ./logs ./logs.db ./logs.db-shm ./logs.db-wal
  stage bazarr         bazarr          "$V/bazarr"             ./config/log
  stage sabnzbd        sabnzbd         "$V/sabnzbd"            ./config/logs
  stage qbittorrent    qbittorrent     "$V/qbittorrent"
  stage jellyfin       jellyfin        "$V/jellyfin/config"    ./metadata ./log ./data/trickplay ./data/library.db.old ./data/library.db.bak1
  stage nginx-proxy-manager nginx-proxy-manager "$V/nginx-proxy-manager" ./data/logs
  stage home-assistant homeassistant   "$V/home-assistant"
  stage homebridge     homebridge      "$V/homebridge"
  stage authelia       authelia        "$V/authelia"
  stage open-webui     open-webui      /var/lib/docker/volumes/open-webui_open-webui/_data  ./cache
  stage hermes         ""              /var/lib/hermes/.hermes ./tools ./cache ./logs ./audio_cache ./image_cache
}

# ---------- 2. export readable JSON ----------
arr_get() {  # arr_get <container> <port> <api version> <path> <outfile>
  local key
  key=$(docker exec "$1" sh -c "grep -o '<ApiKey>[^<]*' /config/config.xml | cut -d'>' -f2") || return 1
  docker exec "$1" curl -fsS -H "X-Api-Key: $key" "http://localhost:$2/api/$3/$4" > "$5"
}
do_export() {
  log "=== export"
  local X=$STAGE/exports
  arr_get sonarr 8989 v3 series         "$X/sonarr-series.json"          && log "exported sonarr series" || { log "ERROR sonarr export"; FAIL=1; }
  arr_get sonarr 8989 v3 qualityprofile "$X/sonarr-qualityprofiles.json"
  arr_get sonarr 8989 v3 rootfolder     "$X/sonarr-rootfolders.json"
  arr_get sonarr 8989 v3 downloadclient "$X/sonarr-downloadclients.json"
  arr_get radarr 7878 v3 movie          "$X/radarr-movies.json"          && log "exported radarr movies" || { log "ERROR radarr export"; FAIL=1; }
  arr_get radarr 7878 v3 qualityprofile "$X/radarr-qualityprofiles.json"
  arr_get radarr 7878 v3 rootfolder     "$X/radarr-rootfolders.json"
  arr_get radarr 7878 v3 downloadclient "$X/radarr-downloadclients.json"
  arr_get prowlarr 9696 v1 indexer      "$X/prowlarr-indexers.json"      && log "exported prowlarr indexers" || { log "ERROR prowlarr export"; FAIL=1; }
  # short, human-readable re-download lists (title, year, ids, monitored)
  python3 - "$X" <<'EOF' && log "wrote re-download lists" || { log "ERROR building lists"; }
import json, sys, os
X = sys.argv[1]
s = json.load(open(f"{X}/sonarr-series.json"))
json.dump([{k: x.get(k) for k in ("title", "year", "tvdbId", "imdbId", "tmdbId", "monitored", "qualityProfileId", "seriesType", "path")}
           | {"monitored_seasons": [z["seasonNumber"] for z in x.get("seasons", []) if z.get("monitored")]} for x in s],
          open(f"{X}/redownload-shows.json", "w"), indent=1)
m = json.load(open(f"{X}/radarr-movies.json"))
json.dump([{k: x.get(k) for k in ("title", "year", "tmdbId", "imdbId", "monitored", "qualityProfileId", "hasFile", "path")} for x in m],
          open(f"{X}/redownload-movies.json", "w"), indent=1)
print(f"{len(s)} shows, {len(m)} movies")
EOF
  docker exec actual-ai node /scripts/export-actual.js > "$X/actual-structure.json" 2>/dev/null \
    && log "exported actual rules/categories/payees/accounts" || { log "ERROR actual export"; FAIL=1; }
}

# ---------- 3./4. restic ----------
make_envfile() {  # pass only what restic/rclone need, not the whole .env
  ENVF=$(mktemp); chmod 600 "$ENVF"
  grep -E '^(RESTIC_PASSWORD|RCLONE_CONFIG_GDRIVE_[A-Z_]+)=' "$HL/.env" > "$ENVF" || true
  grep -q '^RESTIC_PASSWORD=.' "$ENVF" || { log "ERROR RESTIC_PASSWORD missing in .env"; exit 1; }
}
restic_run() {  # restic_run <repo> <args...>
  local repo=$1; shift
  docker run --rm --env-file "$ENVF" --hostname debian \
    -v "$B/restic":/repo-local -v "$B/restic-cache":/root/.cache/restic \
    -v "$STAGE":/data/staging:ro -v "$HL":/data/homelab:ro \
    -v /tmp:/restore \
    "$IMG" -r "$repo" "$@"
}
backup_to() {  # backup_to <repo> <label>
  local repo=$1 label=$2
  restic_run "$repo" cat config >/dev/null 2>&1 || { log "init $label repo"; restic_run "$repo" init >>"$LOG" 2>&1 || { log "ERROR init $label"; FAIL=1; return; }; }
  if restic_run "$repo" backup --tag nightly /data/staging /data/homelab --exclude /data/homelab/.git --exclude /data/homelab/backup/logs >>"$LOG" 2>&1; then
    log "backup -> $label OK"
  else log "ERROR backup -> $label"; FAIL=1; return; fi
  restic_run "$repo" forget --tag nightly --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune >>"$LOG" 2>&1 \
    && log "prune $label OK" || { log "ERROR prune $label"; FAIL=1; }
  if [ "$(date +%u)" = 7 ]; then
    restic_run "$repo" check --read-data-subset=10% >>"$LOG" 2>&1 && log "check $label OK" || { log "ERROR check $label"; FAIL=1; }
  fi
}

case "${1:-}" in
  --stage) do_stage; do_export; exit $FAIL ;;
  --snapshots) make_envfile; restic_run "$LOCAL_REPO" snapshots
               grep -q '^RCLONE_CONFIG_GDRIVE_TOKEN=.' "$ENVF" && restic_run "$GDRIVE_REPO" snapshots; exit 0 ;;
esac

log "=================== backup start"
make_envfile
docker image inspect "$IMG" >/dev/null 2>&1 || docker build -q -t "$IMG" "$HL/backup" >>"$LOG" 2>&1
do_stage
do_export
backup_to "$LOCAL_REPO" local
if grep -q '^RCLONE_CONFIG_GDRIVE_TOKEN=.' "$ENVF"; then backup_to "$GDRIVE_REPO" gdrive
else log "WARN  offsite skipped: RCLONE_CONFIG_GDRIVE_TOKEN not set in .env"; FAIL=1; fi
echo "{\"finished\": \"$(date -Is)\", \"ok\": $([ $FAIL = 0 ] && echo true || echo false)}" > "$LOGDIR/last-status.json"
log "=================== backup end ($([ $FAIL = 0 ] && echo OK || echo 'WITH ERRORS - see above'))"
exit $FAIL
