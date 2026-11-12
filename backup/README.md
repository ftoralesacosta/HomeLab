# Backups

One plain bash script run nightly by cron, with no daemons. [`backup.sh`](backup.sh) writes two encrypted, deduplicated [restic](https://restic.net) repositories:

| Copy | Where | Purpose |
|---|---|---|
| Local | `/mnt/data/backups/restic` (2nd NVMe) | fast restores, survives a dead system disk |
| Offsite | Google Drive `homelab-backups` (via rclone) | survives losing the whole server |

Google only ever receives encrypted chunks. Without `RESTIC_PASSWORD` the backups **cannot be read by anyone, including you**, so keep that password in your password manager.

Last verified 2026-11-04: a **full** restore from Google Drive (18,819 files, 1.13 GiB, 87 s) matched staging and `~/HomeLab` with 0 differences. Re-test a restore every few months.

> [!WARNING]
> Lesson from 2026-11-03: with Alpine's packaged `rclone 1.66-DEV`, 4 uploads to Drive "succeeded" but never landed, and restic reported no error. Fixes: official rclone 1.75.2 + restic 0.19.1 in the [Dockerfile](Dockerfile); `restic check` after **every** run, so a silent loss now fails the run; and a fresh repo. The damaged one could only be deleted from the Drive web UI, because the backup app had lost write access to some of its files.

## What it does
1. **Stage.** Each container is paused for about a second while its config folder is copied (GNU tar) into `/mnt/data/backups/staging/<app>`, so SQLite databases are consistent. A trap unpauses everything on exit.
2. **Export.** Human-readable JSON goes to `staging/exports/`:
   - `redownload-shows.json` / `redownload-movies.json`: title, year, tvdb/tmdb/imdb IDs, quality profile, monitored seasons. **This is the list for re-downloading everything onto a new media drive.**
   - full Sonarr/Radarr API dumps: series, movies, quality profiles, root folders, download clients; Prowlarr indexers
   - `actual-structure.json`: Actual Budget accounts, categories, payees, rules, schedules (no transactions; those live in the `actual-budget` staging copy)
3. **restic backup** of `staging/` and the `~/HomeLab` repo, including the gitignored `.env` and local notes but not `.git`. This goes to both repos.
4. **Retention:** 7 daily, 4 weekly, 12 monthly. After every run, `restic check` confirms that every data file exists, in seconds. On Sundays it also downloads and verifies a 10% sample. Any failure sets `"ok": false` in `logs/last-status.json`.

| Included | Excluded (rebuildable) |
|---|---|
| Actual Budget, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Seerr, Bindery, Kavita, SABnzbd, qBittorrent, Jellyfin (DB, users, watch state, config), NPM (+ certs), Home Assistant, Homebridge, Authelia, Open WebUI, Hermes | media files, Jellyfin metadata/trickplay images, *arr cover art, logs, caches, Hermes tools |

## Secrets (`~/HomeLab/.env`)
| Variable | Value |
|---|---|
| `RESTIC_PASSWORD` | long random string, **no quotes** |
| `RCLONE_CONFIG_GDRIVE_TYPE` | `drive` |
| `RCLONE_CONFIG_GDRIVE_SCOPE` | `drive.file` (rclone can only see files it created) |
| `RCLONE_CONFIG_GDRIVE_CLIENT_ID` / `_CLIENT_SECRET` | your own Google OAuth client (see below) |
| `RCLONE_CONFIG_GDRIVE_TOKEN` | whatever `rclone authorize` prints (base64 or JSON; the script handles both) |

The script passes only these variables to the restic container. If the token is missing, the offsite copy is skipped and the run is marked failed.

**Why your own OAuth client:** rclone's built-in client ID is shared by every rclone user worldwide. The first upload stalled on `rateLimitExceeded` and only 746 bytes got through in 8 minutes. With a personal client (free), the first 730 MB upload took about 3 minutes.

Google Cloud project `homelab-backup`, created 2026-11. To redo it:
1. https://console.cloud.google.com → create a project.
2. *APIs & Services → Library* → enable **Google Drive API**. The "Create credentials" wizard is fine to use: pick **User data**, not Application data (which makes a service account).
3. *Google Auth Platform → Branding* (https://console.cloud.google.com/auth/branding): app name, support email, **developer contact email** (at the bottom; easy to miss), home page + authorized domain `ftoralesacosta.me`. **No logo**, because a logo forces Google's verification review.
4. *Audience* (https://console.cloud.google.com/auth/audience) → **Publish app**, so it's In production. The button stays grey until Branding is complete. In Testing mode, refresh tokens expire after 7 days. `drive.file` is non-sensitive, so no verification is needed. The "unverified app" warning at login is expected.
5. *Clients* (https://console.cloud.google.com/auth/clients) → Create client → **Desktop app**. Leave "AI-powered agent" unchecked; use a separate client for agents. The **secret is shown only once**. Later: open the client → *Client secrets* → **+ Add secret**.
6. Get the token on the server through an SSH tunnel. rclone's login redirects the browser to `localhost:53682`:
   ```bash
   ssh -L 53682:localhost:53682 fernando@192.168.4.51        # from the Mac
   ID='…apps.googleusercontent.com'; SECRET='GOCSPX-…'
   B=$(printf '{"scope":"drive.file","client_id":"%s","client_secret":"%s"}' "$ID" "$SECRET" | base64 -w0 | tr -d '=')   # rclone rejects '=' padding
   docker run --rm -it --network host --entrypoint rclone homelab-backup:restic authorize drive "$B"
   ```
   Open the printed `http://127.0.0.1:53682/auth?...` link in the Mac's browser. The consent page must say **homelab-backup** and ask only for "files you use with this app". If it says "rclone" or asks for all of Drive, the blob was empty, so press Ctrl+C. Paste the printed token into `.env`.

Note: with `drive.file`, files are tied to the OAuth client that created them. If you switch clients, the new one can't see the old repo. Re-authorizing the **same** client is fine.

## Usage
```bash
./backup/backup.sh              # full run (what cron does)
./backup/backup.sh --stage      # stage + exports only, no restic
./backup/backup.sh --snapshots  # list snapshots in both repos
cat backup/logs/last-status.json; tail -50 backup/logs/backup.log
```
Cron: `30 3 * * * /home/fernando/HomeLab/backup/backup.sh >> /home/fernando/HomeLab/backup/logs/cron.log 2>&1`

## Restore
`backup.sh --restic local|gdrive <restic command>` runs any restic command with the secrets from `.env`. Inside the container `/restore` is the host's `/tmp`.
```bash
./backup/backup.sh --restic local snapshots                                  # or: gdrive
./backup/backup.sh --restic local ls latest /data/staging/sonarr             # browse
./backup/backup.sh --restic local restore latest --include /data/staging/actual-budget --target /restore
```
Files land in `/tmp/data/staging/<app>/` (owned by root). To put one app back: `docker stop <app>`, then `sudo cp -a /tmp/data/staging/<app>/. <host path>/`, then `docker start <app>`.

| Staging folder | Host path |
|---|---|
| `actual-budget` | `~/.volumes/actual-budget/data` |
| `sonarr`, `radarr`, `lidarr`, `prowlarr`, `seerr`, `bindery`, `kavita` | `~/.volumes/<app>/config` |
| `bazarr`, `sabnzbd`, `qbittorrent`, `nginx-proxy-manager`, `home-assistant`, `homebridge`, `authelia` | `~/.volumes/<app>` |
| `jellyfin` | `~/.volumes/jellyfin/config` |
| `open-webui` | docker volume `open-webui_open-webui` (`/var/lib/docker/volumes/open-webui_open-webui/_data`) |
| `hermes` | `/var/lib/hermes/.hermes` |
| `minecraft` / `minecraft-1.17.1` | `~/.volumes/minecraft-server_SNAPSHOT/data` / `~/.volumes/minecraft-server_1.17.1/data` |

### Roll the Minecraft world back to an earlier day
Every snapshot contains the world, so the retention above (7 daily, 4 weekly, 12 monthly) is its version history. Only changed chunks are stored, so this costs a few MB per day.
```bash
./backup/backup.sh --restic local snapshots      # pick an ID by date (times are UTC)
./backup/backup.sh --restic local restore <ID> --include /data/staging/minecraft/Fun4All --target /restore
docker stop minecraft-server
sudo mv ~/.volumes/minecraft-server_SNAPSHOT/data/Fun4All /tmp/Fun4All.before-rollback   # keep current, just in case
sudo cp -a /tmp/data/staging/minecraft/Fun4All ~/.volumes/minecraft-server_SNAPSHOT/data/
docker start minecraft-server
```

## Disaster recovery: re-downloading all media
Media files aren't backed up; they're too big and they're replaceable. Instead, the backup holds everything needed to re-download them automatically:
- **Sonarr/Radarr configs**: every show and movie, quality profiles, which seasons you want
- **Prowlarr**: indexers and their API keys
- **SABnzbd/qBittorrent**: Usenet provider login and torrent client settings
- **`exports/redownload-*.json`**: a plain list (title, year, tvdb/tmdb/imdb IDs, path, monitored seasons), in case the configs themselves are unusable

> [!IMPORTANT]
> Keep **outside this server** (password manager): `RESTIC_PASSWORD`, `RCLONE_CONFIG_GDRIVE_CLIENT_ID`, `RCLONE_CONFIG_GDRIVE_CLIENT_SECRET`. The token can be regenerated, but only with the **same** client. A new client can't see the existing repo, because of the `drive.file` scope.

### A. Only the media drive died (server OK)
1. Install the new drive and mount it at **`/mnt/media`**. Same path: everything in Docker expects it. Update `/etc/fstab` with the new UUID (`sudo blkid`).
2. Recreate the root folders:
   `sudo mkdir -p /mnt/media/{Shows,Anime,Movies} && sudo chown -R 1000:1000 /mnt/media`
3. Restart the stack: `docker restart sonarr radarr jellyfin`.
4. **Sonarr:** *Series → Update All* (it notices the files are gone), then *Wanted → Missing → Search All*.
   **Radarr:** *Movies → Update All*, then *Wanted → Missing → Search All*.
5. Downloads land in `/mnt/data/Downloads` and get imported into `/mnt/media/...`. Jellyfin picks them up as they arrive; you can also use *Dashboard → Scan All Libraries*.

Titles that were unmonitored stay unmonitored and won't be searched; that's on purpose. Check that *Settings → Media Management → "Unmonitor deleted episodes/movies"* is **off** before step 4. It was off as of 2026-11-03; if it's on, missing files get unmonitored instead of re-downloaded.

### B. The whole server died
Rebuild the box from **two sources**: **git** (this repo — compose file, scripts, docs) and **restic** (every app's data, databases and secrets, from Google Drive). Media files are *not* restored; step 11 re-downloads them. Budget about an hour, mostly the restic download.

**Before you start**, have these three values from your password manager: `RESTIC_PASSWORD`, `RCLONE_CONFIG_GDRIVE_CLIENT_ID`, `RCLONE_CONFIG_GDRIVE_CLIENT_SECRET`. Everything else — the full `.env`, the Authelia config, every app database — comes out of the restic snapshot in step 4.

**1. Base system.** Install Debian 12, set the hostname to `debian`, give it the LAN address **192.168.4.51** (DHCP reservation or static), and confirm `ssh fernando@192.168.4.51` works. Then install the tooling. Note that the `docker compose` **v2 plugin** must come from Docker's own apt repo:
```bash
sudo apt-get update
sudo apt-get install -y git python3 curl ca-certificates gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker fernando      # then log out and back in (or run: newgrp docker)
docker compose version && docker run --rm hello-world
```

**2. Clone the repo and build the backup image.**
```bash
git clone https://github.com/ftoralesacosta/HomeLab ~/HomeLab
docker build -t homelab-backup:restic ~/HomeLab/backup
```

**3. Write a minimal `.env` — only what restic needs.** Create `~/HomeLab/.env` (mode 600) with just these five lines, then add a fresh Google token:
```bash
cat > ~/HomeLab/.env <<'EOF'
RESTIC_PASSWORD=...
RCLONE_CONFIG_GDRIVE_TYPE=drive
RCLONE_CONFIG_GDRIVE_SCOPE=drive.file
RCLONE_CONFIG_GDRIVE_CLIENT_ID=xxxx.apps.googleusercontent.com
RCLONE_CONFIG_GDRIVE_CLIENT_SECRET=xxxx
EOF
chmod 600 ~/HomeLab/.env
```
Mint the token over an SSH tunnel (rclone's login redirects to `localhost:53682`):
```bash
ssh -L 53682:localhost:53682 fernando@192.168.4.51        # run this on your laptop

ID='xxxx.apps.googleusercontent.com'; SECRET='xxxx'        # back on the server
B=$(printf '{"scope":"drive.file","client_id":"%s","client_secret":"%s"}' "$ID" "$SECRET" | base64 -w0 | tr -d '=')
docker run --rm -it --network host --entrypoint rclone homelab-backup:restic authorize drive "$B"
# open the printed http://127.0.0.1:53682/auth?... link, then append the printed token:
echo 'RCLONE_CONFIG_GDRIVE_TOKEN=<paste the whole token>' >> ~/HomeLab/.env
```
> **Use the same Google OAuth client as before.** With the `drive.file` scope the files belong to that client; a different client cannot see the existing repo. A new *secret* added to the same client is fine.

**4. Restore everything from restic.** This writes to `/tmp/data/{staging,homelab}` (the container's `/restore` is the host's `/tmp`). About 1 min per GB:
```bash
cd ~/HomeLab
./backup/backup.sh --restic gdrive restore latest --target /restore
```
If the second NVMe (`/mnt/data`) survived, mount it first and use the faster local copy instead: `./backup/backup.sh --restic local restore latest --target /restore`.

**5. Put the real config tree and secrets back.** The snapshot holds the whole `~/HomeLab`, including the gitignored files (`.env`, `authelia/configuration.yml`, `authelia/users/auth_file.yml`, `signup/smtp.env`, `OpenWRT-BPI_R4/local/`):
```bash
sudo cp -a /tmp/data/homelab/. ~/HomeLab/
sudo chown -R fernando:fernando ~/HomeLab
chmod 600 ~/HomeLab/.env
```

**6. Mount the disks.** Second NVMe at `/mnt/data` (downloads + local backups) and the media drive at `/mnt/media`:
```bash
sudo mkdir -p /mnt/media /mnt/data
sudo blkid            # copy each UUID into /etc/fstab
```
`/etc/fstab` lines (same as the original server):
```
UUID=<data-uuid>  /mnt/data   ext4  defaults         0 2
UUID=<media-uuid> /mnt/media  ext4  defaults,nofail  0 2
```
```bash
sudo mount -a
sudo mkdir -p /mnt/media/{Shows,Anime,Movies} /mnt/data/{Downloads,backups}
sudo chown -R 1000:1000 /mnt/media /mnt/data
```

**7. Copy each app's data back** using the [Staging folder → Host path](#restore) table above. The *arr apps, for example:
```bash
for app in sonarr radarr lidarr prowlarr seerr bindery kavita; do
  sudo mkdir -p ~/.volumes/$app/config
  sudo cp -a /tmp/data/staging/$app/. ~/.volumes/$app/config/
done
```
Repeat for every row you need (`bazarr`, `sabnzbd`, `qbittorrent`, `nginx-proxy-manager`, `home-assistant`, `homebridge`, `authelia`, `jellyfin`, `actual-budget`, `open-webui`, `hermes`, `minecraft`), then fix ownership:
```bash
sudo mkdir -p ~/.volumes/bindery        # must exist and be owned by 1000 before start
sudo chown -R 1000:1000 ~/.volumes
```

**8. Start the whole stack.**
```bash
cd ~/HomeLab
docker compose up -d
docker compose ps                       # everything Up (or healthy)
```

**9. Harden the host and reinstall the systemd pieces.**
```bash
sudo bash ~/HomeLab/server/harden-host.sh          # fail2ban + unattended security upgrades
sudo bash ~/HomeLab/systemd/install-hermes-env.sh  # hermes-env.service + hermes-gateway drop-in
```
`hermes-gateway.service` itself is **not** in this repo — it ships with the Hermes install. Reinstall Hermes first, then run `install-hermes-env.sh` so the drop-in applies.

**10. Re-add the cron jobs** (`crontab -e`):
```
30 3 * * * /home/fernando/HomeLab/backup/backup.sh >> /home/fernando/HomeLab/backup/logs/cron.log 2>&1
45 5 * * * timeout 900 docker exec actual-ai node /scripts/bank-sync.js >> /home/fernando/HomeLab/actual-ai/logs/cron.log 2>&1
45 6 * * * docker exec actual-ai node /scripts/daily-fixups.js >> /home/fernando/HomeLab/actual-ai/logs/cron.log 2>&1
```

**11. Re-download the media** — do **steps A4–A5** above (Sonarr/Radarr *Update All* → *Wanted → Missing → Search All*).

**12. Confirm backups are healthy again.**
```bash
./backup/backup.sh
cat backup/logs/last-status.json        # expect "ok": true
```

### C. The Sonarr/Radarr configs are lost or broken too
Start fresh Sonarr/Radarr. Set up Prowlarr and the download clients, or restore just those apps. Then re-add every title from the list ([`readd-media.py`](readd-media.py), stdlib Python, dry run by default):
```bash
cd ~/HomeLab
./backup/backup.sh --restic gdrive restore latest --include /data/staging/exports --target /restore
# Sonarr/Radarr have no published ports, so run the script in a throwaway python container on their network:
export SONARR_API_KEY=$(docker exec sonarr sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)
export RADARR_API_KEY=$(docker exec radarr sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)
RUN() { docker run --rm --network homelab_proxy-net -e SONARR_API_KEY -e RADARR_API_KEY \
        -v "$PWD/backup":/app:ro -v /tmp/data/staging/exports:/x:ro python:3.12-alpine \
        python /app/readd-media.py /x --sonarr http://sonarr:8989 --radarr http://radarr:7878 "$@"; }
RUN                    # dry run: lists what it would add
RUN --apply --search   # add everything and start searching
```
It keeps the original folder paths, monitored seasons and quality profiles (matched by name), and skips titles that already exist. Tested 2026-11-04: fresh empty Sonarr/Radarr ended up with 9/9 shows and 23/23 movies, with the same paths, seasons and monitored flags.
