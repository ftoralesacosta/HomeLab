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
#               - offsite: Google Drive  homelab-backups  (via rclone)
#  4. PRUNE   keep 7 daily, 4 weekly, 12 monthly snapshots;  Sundays: integrity check
#
# Needs in ~/HomeLab/.env:  RESTIC_PASSWORD  (+ RCLONE_CONFIG_GDRIVE_* for the offsite copy)
# Usage:  backup.sh            full run
#         backup.sh --stage    only steps 1-2 (no restic)
#         backup.sh --snapshots   list snapshots in both repos
#         backup.sh --restic local|gdrive <restic args>   e.g. restore latest --target /restore (= host /tmp)
# Log: ~/HomeLab/backup/logs/backup.log   Restore: see ~/HomeLab/backup/README.md
# =============================================================================
set -uo pipefail
HL=/home/fernando/HomeLab
V=/home/fernando/.volumes
B=/mnt/data/backups
STAGE=$B/staging
LOCAL_REPO=/repo-local
GDRIVE_REPO=rclone:gdrive:homelab-backups
IMG=homelab-backup:restic
LOGDIR=$HL/backup/logs; LOG=$LOGDIR/backup.log
mkdir -p "$LOGDIR"
FAIL=0
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

PAUSED=()
unpause_all() { for c in "${PAUSED[@]}"; do docker unpause "$c" >/dev/null 2>&1; done; PAUSED=(); }
MC_SAVE_OFF=0
mc_save_on() { [ $MC_SAVE_OFF = 1 ] && docker exec minecraft-server rcon-cli save-on >/dev/null 2>&1; MC_SAVE_OFF=0; }
cleanup() { unpause_all; mc_save_on; rm -f "${ENVF:-}"; }
trap cleanup EXIT

# ---------- 1. stage ----------
# stage <name> <container-to-pause or ""> <source dir> [exclude patterns relative to source, e.g. ./log]
stage() {
  local name=$1 ctr=$2 src=$3; shift 3
  local ex=(--no-wildcards-match-slash) e   # so './*.jar' matches top level only
  for e in "$@"; do ex+=("--exclude='$e'"); done
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
  stage seerr          seerr           "$V/seerr/config"
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
  # Minecraft: not paused (players would time out); flush the world to disk and stop autosave while copying.
  # Excludes are rebuildable (server jars/libraries) or junk (JVM core dumps, crash reports, old tarballs).
  if docker ps --format '{{.Names}}' | grep -qx minecraft-server \
     && docker exec minecraft-server rcon-cli save-off >/dev/null 2>&1; then
    MC_SAVE_OFF=1
    docker exec minecraft-server rcon-cli save-all flush >/dev/null 2>&1; sleep 5
  else log "WARN  minecraft: rcon save-off failed, copying without flush"; fi
  stage minecraft      ""              "$V/minecraft-server_SNAPSHOT/data" ./core ./crash-reports ./logs './hs_err_pid*' './*.jar' ./libraries ./versions ./.cache
  mc_save_on
  stage minecraft-1.17.1 ""            "$V/minecraft-server_1.17.1/data" ./core ./crash-reports ./logs './*.jar' ./libraries ./versions
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
  # rclone >= 1.70 "authorize" prints base64({client_id, client_secret, token}); rclone 1.66 here wants the plain token JSON.
  python3 - "$ENVF" <<'EOF'
import base64, json, sys
p = sys.argv[1]; lines = open(p).read().splitlines(); out = []
for l in lines:
    k, _, v = l.partition("=")
    if k == "RCLONE_CONFIG_GDRIVE_TOKEN" and v and not v.startswith("{"):
        d = json.loads(base64.b64decode(v + "=" * (-len(v) % 4)))
        t = d["token"]; t = json.loads(t) if isinstance(t, str) else t
        out.append(k + "=" + json.dumps(t, separators=(",", ":")))
    else:
        out.append(l)
open(p, "w").write("\n".join(out) + "\n")
EOF
}
restic_run() {  # restic_run <repo> <args...>
  local repo=$1; shift
  ${TMO:+timeout $TMO} docker run --rm --env-file "$ENVF" --hostname debian \
    -v "$B/restic":/repo-local -v "$B/restic-cache":/root/.cache/restic \
    -v "$STAGE":/data/staging:ro -v "$HL":/data/homelab:ro \
    -v /tmp:/restore \
    "$IMG" -r "$repo" "$@"
}
backup_to() {  # backup_to <repo> <label>
  local repo=$1 label=$2
  restic_run "$repo" cat config >/dev/null 2>&1 || { log "init $label repo"; restic_run "$repo" init >>"$LOG" 2>&1 || { log "ERROR init $label"; FAIL=1; return; }; }
  restic_run "$repo" unlock >/dev/null 2>&1   # removes only stale locks (e.g. from a killed run)
  # 3h cap: timeout's SIGTERM is proxied by `docker run` to restic, which stops cleanly (next run resumes, dedup keeps what was uploaded)
  if TMO=3h restic_run "$repo" backup --tag nightly /data/staging /data/homelab --exclude /data/homelab/.git --exclude /data/homelab/backup/logs >>"$LOG" 2>&1; then
    log "backup -> $label OK"
  else log "ERROR backup -> $label"; FAIL=1; return; fi
  restic_run "$repo" forget --tag nightly --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune >>"$LOG" 2>&1 \
    && log "prune $label OK" || { log "ERROR prune $label"; FAIL=1; }
  # Every run: verify that every pack the index lists really exists (a listing, takes seconds).
  # This is what caught Google Drive silently dropping uploads on 2026-11-03.
  # Sundays: additionally download and verify 10% of the data.
  local chk=(check); [ "$(date +%u)" = 7 ] && chk+=(--read-data-subset=10%)
  restic_run "$repo" "${chk[@]}" >>"$LOG" 2>&1 && log "check $label OK" || { log "ERROR check $label - repository damaged, see log"; FAIL=1; }
}

case "${1:-}" in
  --stage) do_stage; do_export; exit $FAIL ;;
  --restic) # any restic command against local|gdrive, e.g. --restic gdrive restore latest --target /restore  (/restore = host /tmp)
           make_envfile; r=$LOCAL_REPO; [ "${2:-}" = gdrive ] && r=$GDRIVE_REPO; shift 2; restic_run "$r" "$@"; exit $? ;;
  --snapshots) make_envfile; restic_run "$LOCAL_REPO" snapshots
               grep -q '^RCLONE_CONFIG_GDRIVE_TOKEN=.' "$ENVF" && restic_run "$GDRIVE_REPO" snapshots; exit 0 ;;
esac

exec 9>/tmp/homelab-backup.lock
flock -n 9 || { log "another backup.sh is still running - skipping this run"; exit 1; }
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
