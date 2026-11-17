#!/bin/sh
# receipt-watch.sh: rebuild the receipt pages (scripts/receipt-pages.js) soon after the budget changes.
# Actual has no webhooks, but every synced edit (from any device, bank sync or daily-fixups.js) is
# written to the sync server's group-*.sqlite. This checks that file's mtime and only rebuilds when it moved.
# Cost when idle: one stat per run. Rebuild ~0.5 s. Run every minute from fernando's crontab:
#   * * * * * /home/fernando/HomeLab/actual-ai/receipt-watch.sh
# Force a rebuild:  receipt-watch.sh --force
set -eu
DATA=/home/fernando/.volumes/actual-budget/data/user-files
STAMP=/home/fernando/HomeLab/actual-ai/logs/.receipt-watch.stamp
LOG=/home/fernando/HomeLab/actual-ai/logs/cron.log

exec 9>"$STAMP.lock"
flock -n 9 || exit 0   # a rebuild is already running

now=$(stat -c %Y "$DATA"/group-*.sqlite 2>/dev/null | sort -n | tail -1)
[ -n "$now" ] || exit 0
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ "${1:-}" = "--force" ] || [ "$now" != "$last" ] || exit 0

# edits that land while this runs move the mtime again and get picked up next minute
if docker exec actual-ai node /scripts/receipt-pages.js >>"$LOG" 2>&1; then
  echo "$now" > "$STAMP"
fi
