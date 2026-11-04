# Backups

One plain bash script run nightly by cron, with no daemons. [`backup.sh`](backup.sh) writes two encrypted, deduplicated [restic](https://restic.net) repositories:

| Copy | Where | Purpose |
|---|---|---|
| Local | `/mnt/data/backups/restic` (2nd NVMe) | fast restores, survives a dead system disk |
| Offsite | Google Drive `homelab-backups/restic` (via rclone) | survives losing the whole server |

Google only ever receives encrypted chunks. Without `RESTIC_PASSWORD` the backups **cannot be read by anyone, including you**, so keep that password in your password manager.

## What it does
1. **Stage.** Each container is paused for about a second while its config folder is copied (GNU tar) into `/mnt/data/backups/staging/<app>`, so SQLite databases are consistent. A trap unpauses everything on exit.
2. **Export.** Human-readable JSON goes to `staging/exports/`:
   - `redownload-shows.json` / `redownload-movies.json`: title, year, tvdb/tmdb/imdb IDs, quality profile, monitored seasons. **This is the list for re-downloading everything onto a new media drive.**
   - full Sonarr/Radarr API dumps: series, movies, quality profiles, root folders, download clients; Prowlarr indexers
   - `actual-structure.json`: Actual Budget accounts, categories, payees, rules, schedules (no transactions; those live in the `actual-budget` staging copy)
3. **restic backup** of `staging/` and the `~/HomeLab` repo, including the gitignored `.env` and local notes but not `.git`. This goes to both repos.
4. **Retention:** 7 daily, 4 weekly, 12 monthly. On Sundays it also runs `restic check` on a 10% sample of the data.

| Included | Excluded (rebuildable) |
|---|---|
| Actual Budget, Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, qBittorrent, Jellyfin (DB, users, watch state, config), NPM (+ certs), Home Assistant, Homebridge, Authelia, Open WebUI, Hermes | media files, Jellyfin metadata/trickplay images, logs, caches, Hermes tools |

## Secrets (`~/HomeLab/.env`)
| Variable | Value |
|---|---|
| `RESTIC_PASSWORD` | long random string, **no quotes** |
| `RCLONE_CONFIG_GDRIVE_TYPE` | `drive` |
| `RCLONE_CONFIG_GDRIVE_SCOPE` | `drive.file` (rclone can only see files it created) |
| `RCLONE_CONFIG_GDRIVE_CLIENT_ID` / `_CLIENT_SECRET` | your own Google OAuth client (see below) |
| `RCLONE_CONFIG_GDRIVE_TOKEN` | whatever `rclone authorize` prints (base64 or JSON; the script handles both) |

The script passes only these variables to the restic container. If the token is missing, the offsite copy is skipped and the run is marked failed.

**Why your own OAuth client:** rclone's built-in client ID is shared by every rclone user worldwide. The first upload stalled on `rateLimitExceeded` and only 746 bytes got through in 8 minutes. A personal client gets its own quota, and it's free.
1. https://console.cloud.google.com → create a project (e.g. `homelab-backup`).
2. *APIs & Services → Library* → enable **Google Drive API**.
3. *Google Auth Platform* (OAuth consent screen) → Get started → app name, your email, Audience **External** → Create.
4. *Audience* → **Publish app** (In production). In "Testing" mode, refresh tokens expire after 7 days. `drive.file` is a non-sensitive scope, so Google doesn't need to verify the app.
5. *Clients* → Create client → type **Desktop app** → copy the Client ID and Client secret.
6. On a machine with a browser:
   ```bash
   ID='…apps.googleusercontent.com'; SECRET='…'
   rclone authorize drive "$(printf '{"scope":"drive.file","client_id":"%s","client_secret":"%s"}' "$ID" "$SECRET" | base64)"
   ```

Note: with `drive.file`, files are tied to the OAuth client that created them. If you switch clients, the new one can't see the old repo.

## Usage
```bash
./backup/backup.sh              # full run (what cron does)
./backup/backup.sh --stage      # stage + exports only, no restic
./backup/backup.sh --snapshots  # list snapshots in both repos
cat backup/logs/last-status.json; tail -50 backup/logs/backup.log
```
Cron: `30 3 * * * /home/fernando/HomeLab/backup/backup.sh >> /home/fernando/HomeLab/backup/logs/cron.log 2>&1`

## Restore
Shell helper (run from `~/HomeLab`):
```bash
R() { docker run --rm -it --env-file <(grep -E '^(RESTIC_PASSWORD|RCLONE_CONFIG_GDRIVE_[A-Z_]+)=' .env) \
      -v /mnt/data/backups/restic:/repo-local -v /tmp/restore:/restore homelab-backup:restic "$@"; }
R -r /repo-local snapshots                          # or: -r rclone:gdrive:homelab-backups/restic
R -r /repo-local ls latest /data/staging/sonarr     # browse
R -r /repo-local restore latest --include /data/staging/actual-budget --target /restore
```
Files land in `/tmp/restore/data/staging/<app>/`. To put one back: `docker stop <app>`, copy the files over `~/.volumes/<app>` (use a root helper container for root-owned files), then `docker start <app>`.

**New server from scratch:** install Docker and git, clone this repo, then `docker build -t homelab-backup:restic backup/`. Recreate `.env` with just the 4 variables above, restore `latest` from Google Drive, copy `data/homelab/.env` back, copy each `data/staging/<app>` to `~/.volumes/<app>`, and run `docker compose up -d`.

**New media drive:** the restored Sonarr/Radarr still know every show and movie. Point the root folders at the new drive, then run *Wanted → Missing → Search All* in each. If the *arr configs are lost too, re-add titles from `redownload-*.json` (each entry has its tvdb/tmdb ID) through the API or by hand.
