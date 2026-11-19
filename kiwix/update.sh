#!/usr/bin/env bash
# Download / update Kiwix ZIM files and keep library.xml in sync.
#
#   ~/HomeLab/kiwix/update.sh            # fetch newer ZIMs for every entry in BOOKS
#   ~/HomeLab/kiwix/update.sh --check    # only report what would be downloaded
#
# Flow per book: newest file name from the Kiwix listing -> resumable multi-mirror
# download (aria2, metalink) into .incoming/ -> verify against the published .sha256 -> rename -> add to
# library.xml -> remove + delete the older version. kiwix-serve runs with
# --monitorLibrary, so no restart is needed. Run monthly from fernando's crontab (2nd of the month, 04:15).
set -euo pipefail

DIR=/mnt/data/kiwix                       # NVMe (random reads); not in restic
LIB=/data/library.xml                     # path as seen inside the container
IMG=ghcr.io/kiwix/kiwix-serve:3.8.2       # same image as the service (has kiwix-manage)
BASE=https://download.kiwix.org/zim
# <listing dir>/<book name without date>. Add more lines for extra ZIMs.
BOOKS=(
  wikipedia/wikipedia_en_all_maxi
)

CHECK=false; [ "${1:-}" = --check ] && CHECK=true
log() { echo "$(date '+%F %T') $*"; }
manage() { docker run --rm -u 1000:1000 -v "$DIR:/data" --entrypoint kiwix-manage "$IMG" "$LIB" "$@"; }

exec 9>"$DIR/.update.lock"
flock -n 9 || { log "another update is running"; exit 0; }

for entry in "${BOOKS[@]}"; do
  sub=${entry%/*}; book=${entry##*/}
  latest=$(curl -fsSL "$BASE/$sub/" | grep -oE "${book}_[0-9]{4}-[0-9]{2}\.zim" | sort -u | tail -1)
  [ -n "$latest" ] || { log "$book: not found in listing"; continue; }
  if [ -f "$DIR/$latest" ]; then log "$book: $latest is current"; continue; fi
  if $CHECK; then log "$book: would download $latest"; continue; fi

  url="$BASE/$sub/$latest"
  size=$(curl -fsSIL "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{s=$2} END{print (s=="" ? "0" : s)}')
  [[ $size =~ ^[0-9]+$ ]] || size=0
  free=$(df --output=avail -B1 "$DIR" | tail -1)
  if [ "$size" -gt 0 ] && [ $((size + size / 10)) -gt "$free" ]; then
    log "$book: not enough space ($size needed, $free free)"; exit 1
  fi

  # aria2 + Kiwix's metalink: parallel download from several mirrors (one mirror
  # alone gave 1-5 MB/s, the metalink ~10+ MB/s). Resumable: rerun to continue.
  log "$book: downloading $latest ($((size / 1024 / 1024 / 1024)) GB) via metalink"
  mkdir -p "$DIR/.incoming"
  docker run --rm -v "$DIR/.incoming:/d" alpine:3 sh -c "apk add -q aria2 >/dev/null && \
    aria2c --dir=/d --continue=true -x16 -s16 --min-split-size=20M --file-allocation=none \
      --max-tries=10 --retry-wait=30 --summary-interval=300 --console-log-level=warn \
      --follow-metalink=mem '$url.meta4' && chown 1000:1000 '/d/$latest'"

  want=$(curl -fsSL "$url.sha256" | awk '{print $1}')
  log "$book: verifying sha256"
  have=$(sha256sum "$DIR/.incoming/$latest" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$have" ]; then
    log "$book: CHECKSUM MISMATCH (want '$want', have '$have') - deleting download"
    rm -f "$DIR/.incoming/$latest" "$DIR/.incoming/$latest.aria2"; exit 1
  fi
  mv "$DIR/.incoming/$latest" "$DIR/$latest"
  [ -f "$DIR/library.xml" ] || echo '<library version="20110515"></library>' > "$DIR/library.xml"
  manage add "/data/$latest"
  log "$book: added $latest to the library"
  UPDATED=1

  # Drop older versions of the same book from the library, then from disk.
  for old in "$DIR/${book}"_*.zim; do
    [ "$old" = "$DIR/$latest" ] && continue
    id=$(manage show | awk -v p="/data/$(basename "$old")" '$1=="id:"{id=$2} $1=="path:" && $2==p {print id}')
    [ -n "$id" ] && manage remove "$id"
    rm -f "$old"; log "$book: removed old $(basename "$old")"
  done
done
# New edition: rebuild the start page (edition date, tile images) and restart kiwix to load it.
if [ "${UPDATED:-0}" = 1 ]; then
  python3 "$(dirname "$(readlink -f "$0")")/landing/build.py" && docker restart kiwix >/dev/null \
    && log "start page rebuilt" || log "WARN start page rebuild failed (Wikipedia itself is updated)"
fi
log "done"
