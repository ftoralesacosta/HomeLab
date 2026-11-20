# HomeLab

Configuration for my home server **`debian`** (192.168.4.51). Most services run in one Docker
Compose stack ([docker-compose.yml](docker-compose.yml)). The repo also holds everything around it:
scheduled jobs, backups, the Hermes agent, the router and host hardening. The domain is
`ftoralesacosta.me`; its DNS is on Cloudflare.

```
Verizon fiber ─► BPI-R4 router (OpenWrt) ─► LAN 192.168.4.0/22 ─► debian (Wi-Fi)
                 forwards TCP 22, 80, 443, 25565 ───────────────► debian
```

**Contents:** [Services](#services) · [Daily operations](#daily-operations) ·
[Scheduled and background tasks](#scheduled-and-background-tasks) · [Proxy hosts](#proxy-hosts-npm) ·
[Login and access](#login-and-access-authelia) · [Secrets](#secrets) · [Downloads](#downloads) ·
[Network](#network) · [Other documents](#other-documents)

## Services

Each web app has its own subdomain, for example `sonarr.ftoralesacosta.me`.

| Area | Services |
|---|---|
| Edge | `reverse-proxy`: Nginx Proxy Manager (NPM) on 80/443, admin UI on port 81 (LAN only). `cloudflare-ddns`: keeps `ftoralesacosta.me`, `mc.` and `wiki.` on the home IP |
| Login | `authelia` (auth.): single sign-on and 2FA. `signup` (signup.): public form to request an account |
| AI | `open-webui` (webui.), `searxng` (web search, LAN only), `local-deep-research` (cited research reports, used from the *Deep Research* model in Open WebUI; not exposed; see [local-deep-research/README.md](local-deep-research/README.md)). Hermes agent: systemd service `hermes-gateway`, not Docker, API on 127.0.0.1:8642 |
| Media | `jellyfin` (player). `sonarr`, `radarr`, `lidarr` (TV, movies, music), `prowlarr` + `flaresolverr` (indexers), `bazarr` (subtitles), `seerr` (family requests) |
| Books | `bindery` (finds and downloads books), `kavita` (reader; shared `Books` library, progress per user) |
| Downloads | `sabnzbd` (Usenet). `qbittorrent` and `slskd` (Soulseek), both inside the `vpn` container (gluetun, ProtonVPN) |
| Home | `homeassistant` (ha.) |
| Knowledge | `kiwix` (wiki.): offline Wikipedia, see [kiwix/README.md](kiwix/README.md) |
| Other | `actual` + `actual-ai` (budget.; receipts.), `mc` (Minecraft, port 25565), `website` (ftoralesacosta.me) |

## Daily operations

Run the commands in `~/HomeLab`.

| Task | Command |
|---|---|
| Start or update one service | `docker compose up -d <service>` |
| Get a newer image | `docker compose pull <service> && docker compose up -d <service>` |
| Add a subdomain | `nginx-proxy-manager/add-host.sh <name>.ftoralesacosta.me <container>:<port> [--authelia]` |
| Add a user | `authelia/add-user.sh <user> <email> "<Name>" <group>` |
| Approve a signup | `authelia/approve-user.sh <user> [family\|friends]` |
| Run the backup now | `backup/backup.sh` (status: `cat backup/logs/last-status.json`) |
| See every scheduled job | `crontab -l`, and the [task tables](#scheduled-and-background-tasks) below |
| Harden a fresh install | `sudo bash server/harden-host.sh` |

- Change one service at a time. Do not restart the full stack.
- Do not use `docker compose down -v` or prune volumes. That deletes app data.

## Scheduled and background tasks

Everything that runs by itself, in one place. There are four kinds:

1. **Cron jobs**: scripts in this repo, run by fernando's crontab. They are the only jobs this
   repo schedules.
2. **Watchers and event hooks**: things that react to a change (a file, the VPN port, a state).
3. **Built-in app schedules**: jobs the apps run themselves. Change them in each app's UI.
4. **Host and router**: Debian's systemd timers, the Hermes services, and the router's fiber-stick service.

### The day at a glance

| Time | What runs | Kind |
|---|---|---|
| every minute | `receipt-watch.sh` (rebuilds receipt pages if the budget changed) | cron |
| every 5 min | `cloudflare-ddns` checks the home IP | app |
| 00:00 – 06:30 | Debian: logrotate, apt lists, unattended security upgrades (no reboot) | host |
| 03:00 – 05:00 | Seerr scans (Jellyfin 03:00, Radarr 04:00, Sonarr 04:30, availability 05:00) | app |
| **03:30** | **`backup.sh`**: pause, copy, Minecraft flush over RCON, restic to NVMe + Google Drive | cron |
| **05:45** | **`bank-sync.js`**: bank sync for each Actual account | cron |
| 06:00 | `actual-ai` categorizes new transactions | app |
| **06:45** | **`daily-fixups.js`**: links transfers, refunds, notes | cron |
| **2nd of month, 04:15** | **`kiwix/update.sh`**: newer Wikipedia ZIM, checksum-verified | cron |
| weekly | Sun: the backup also reads back 10 % of its data; ext4 scrub 03:10. Mon ~01:00: SSD `fstrim` | cron / host |

### 1. Cron jobs (fernando's crontab)

| Schedule | Job | What it does | Log |
|---|---|---|---|
| `* * * * *` every minute | [`actual-ai/receipt-watch.sh`](actual-ai/receipt-watch.sh) | Actual has no webhooks, so this polls. It checks the modification time of the sync server's `group-*.sqlite`, which every synced edit changes (any device, bank sync, `daily-fixups.js`). Only if it changed does it run `receipt-pages.js`, which rebuilds https://receipts.ftoralesacosta.me (~0.5 s). Idle cost: one `stat`. A lock stops overlapping runs. `--force` rebuilds now | `actual-ai/logs/cron.log` |
| `30 3 * * *` daily 03:30 | [`backup/backup.sh`](backup/backup.sh) | 1. **Stage:** copy each app's data to `/mnt/data/backups/staging`, pausing each container for the few seconds its folder takes. **Minecraft is not paused** (players would time out): over **RCON** it runs `save-off`, then `save-all flush`, copies the world, then `save-on`. 2. **Export:** readable JSON (Sonarr/Radarr lists, Actual structure). 3. **Backup:** restic snapshot to the local repo on the second NVMe and to Google Drive. 4. **Prune** 7 daily / 4 weekly / 12 monthly, then `restic check` (Sundays: also reads back 10 % of the data). Details: [backup/README.md](backup/README.md) | `backup/logs/backup.log`, `cron.log`, `last-status.json` |
| `45 5 * * *` daily 05:45 | [`actual-ai/scripts/bank-sync.js`](actual-ai/scripts/bank-sync.js) (`timeout 900`) | Syncs each bank account on its own, so one broken bank connection does not stop the others | `actual-ai/logs/cron.log` |
| `45 6 * * *` daily 06:45 | [`actual-ai/scripts/daily-fixups.js`](actual-ai/scripts/daily-fixups.js) | No AI. Links payments between my own accounts, gives refunds the purchase's category, and writes the notes line with the `[receipt]` link. Every change goes to `daily-fixups.jsonl` with undo data. See [ActualBudget/README.md](ActualBudget/README.md) | `actual-ai/logs/cron.log` |
| `15 4 2 * *` monthly, 2nd, 04:15 | [`kiwix/update.sh`](kiwix/update.sh) | Looks for a newer Wikipedia ZIM. If there is one: multi-mirror download (aria2), sha256 check, add it to `library.xml`, delete the old one. Kiwix reloads by itself. See [kiwix/README.md](kiwix/README.md) | `kiwix/logs/cron.log` |

The whole crontab, as it should be (`crontab -e`; also used by the restore runbook):

```
* * * * * /home/fernando/HomeLab/actual-ai/receipt-watch.sh
30 3 * * * /home/fernando/HomeLab/backup/backup.sh >> /home/fernando/HomeLab/backup/logs/cron.log 2>&1
45 5 * * * timeout 900 docker exec actual-ai node /scripts/bank-sync.js >> /home/fernando/HomeLab/actual-ai/logs/cron.log 2>&1
45 6 * * * docker exec actual-ai node /scripts/daily-fixups.js >> /home/fernando/HomeLab/actual-ai/logs/cron.log 2>&1
15 4 2 * * /home/fernando/HomeLab/kiwix/update.sh >> /home/fernando/HomeLab/kiwix/logs/cron.log 2>&1
```

Run a job by hand with the same command. All logs are gitignored.

### 2. Watchers and event hooks

| What | Trigger | Effect |
|---|---|---|
| Authelia user file | `authelia/users/auth_file.yml` changes (`signup`, `add-user.sh`, `approve-user.sh`) | Authelia reloads users with no restart (`file.watch`; the repo mounts the folder so the watcher works) |
| VPN port forwarding | gluetun gets a forwarded port, or loses it | Up command: qBittorrent moves to the forwarded port and leaves `lo`. Down command: it parks on `lo` (no leaks). In the `vpn` service in compose |
| Kiwix library | `/mnt/data/kiwix/library.xml` changes | `kiwix-serve --monitorLibrary` serves the new ZIM with no restart |
| Kavita `Books` library | Files appear in `/media/Books` | Folder watching adds them (Bindery drops books there) |
| Home Assistant | `input_boolean.energy_saver` or `climate.living` changes, or HA starts | Automations *Energy Saver Control* / *Energy Saver Sync* ([automations.yaml](HomeAssistant/automations.yaml)) |
| Containers | A crash or a reboot | `restart: unless-stopped` on every service |

### 3. Built-in app schedules

These live in each app's database, not in this repo. Change them in the app's UI.

| App | Schedule |
|---|---|
| `actual-ai` | Categorizes daily at 06:00 (`CLASSIFICATION_SCHEDULE_CRON` in compose) |
| `cloudflare-ddns` | Checks the public IP every 5 min and updates `@`, `mc.` and `wiki.` |
| Local Deep Research | Cleanup of inactive sessions every 5 min; its news scheduler (only runs subscriptions you create) |
| Seerr | Jellyfin recently added: every 5 min · full scan 03:00 · Radarr 04:00 · Sonarr 04:30 · availability 05:00 · download sync every minute |
| Bindery | Metadata refresh hourly, library scan, search for wanted books (13 jobs) |
| Kavita | Library scan, backup and cleanup tasks, daily (Settings → Tasks) |
| Sonarr, Radarr, Lidarr, Prowlarr, Bazarr | Their usual tasks: RSS sync, refresh, indexer sync, housekeeping (System → Tasks) |
| Jellyfin | Library scans, trickplay and image extraction (Dashboard → Scheduled Tasks) |

### 4. Host and router

| Unit | When | What |
|---|---|---|
| `apt-daily` / `apt-daily-upgrade` | daily | Package lists and **security upgrades only**, never a reboot (set by `server/harden-host.sh`). Other updates are manual |
| `logrotate`, `dpkg-db-backup` | daily 00:00 | Debian housekeeping |
| `fstrim.timer` | weekly | TRIM on the SSDs |
| `e2scrub_all.timer` | Sundays 03:10 | ext4 metadata check |
| `smartd` | always | Watches disk SMART health |
| `hermes-env.service` | at boot, before Hermes | Copies Hermes's two keys from `.env` into root-only `/run/hermes-gateway.env` ([systemd/](systemd/)) |
| `hermes-gateway.service` | always (`Restart=always`) | Hermes agent API on 127.0.0.1:8642, user `hermes` |
| Router: `/etc/init.d/gpon-stick` | always | Keeps the fiber stick's link up: forces autoneg off every 5 s and sends a 1/s keepalive ping. See [OpenWRT-BPI_R4/README.md](OpenWRT-BPI_R4/README.md) |

`systemctl list-timers` lists the host timers.

### Adding a scheduled job

1. Put the script in the repo, next to what it serves, with absolute paths (cron has no `~` and a small `PATH`).
2. Take a lock (`flock -n`) so a slow run is not started twice, and log to `<folder>/logs/cron.log`
   (add `<folder>/logs/` to `.gitignore`).
3. Add it to `crontab -e`, **and** to the tables and the crontab block above.

## Proxy hosts (NPM)

NPM keeps its proxy hosts in its own database, not in this repo. Change them in the NPM UI
(http://192.168.4.51:81 at home; away: `ssh -L 8181:localhost:81 fernando@ftoralesacosta.me`, then
http://localhost:8181), or with `nginx-proxy-manager/add-host.sh`. The script asks for the NPM
admin password and does not store it.

```bash
add-host.sh --list                                    # all hosts: target, SSL, gate
add-host.sh kavita.ftoralesacosta.me kavita:5000      # new host
add-host.sh <name> <container>:<port> --authelia      # new host behind the gate
add-host.sh <name> <container>:<port> --update ...    # change a host; the flags replace its settings
add-host.sh <name> <container>:<port> --update --advanced ''   # remove the gate (empty Advanced config)
add-host.sh --delete <name>                           # --dry-run shows a change, --help lists all flags
```

- Use the container name as the target, not the host IP. NPM shares `proxy-net` with the apps.
- New hosts use the wildcard certificate `*.ftoralesacosta.me` (certificate 7). Force SSL,
  WebSockets, HTTP/2 and "Block Common Exploits" are on by default.
- A gated host also needs an `access_control` rule in Authelia. Until it has one, Authelia refuses everyone.
- A new subdomain also needs a DNS record in Cloudflare (proxied).
- Errors: 401 = wrong email or password, 400 = the name exists or the target is wrong,
  502 = wrong container or port, or the container is not on `proxy-net`.

## Login and access (Authelia)

https://auth.ftoralesacosta.me is the login for every app except Home Assistant's own second
login. Gated apps need a second factor (TOTP or security key). Details: [authelia/README.md](authelia/README.md).

| Group | Access |
|---|---|
| `admin` | Everything |
| `family` | Media and book apps, Open WebUI, Wikipedia |
| `friends` | Open WebUI and Wikipedia |
| `pending` | Nothing. New signups wait here until I approve them |

| App | How it logs in | Who |
|---|---|---|
| Home Assistant | Gate, then HA's own login (HA cannot trust a proxy login). The companion app uses HA tokens on `/api/` and `/auth/token` | admin |
| SABnzbd, qBittorrent, slskd | Gate. Their own logins are off: SABnzbd has no user name, qBittorrent skips its login for `proxy-net` (`WebUI\AuthSubnetWhitelist=172.23.0.0/16`), slskd auth is off | admin |
| receipts. | Gate | admin |
| *arr apps | Gate. `/api` skips the gate for API-key clients | admin, family |
| Bazarr | Gate. Its own login is off (`auth.type: null` in its `config.yaml`) | admin, family |
| Bindery | Gate. Bindery takes the user name from the gate | admin, family |
| Kiwix (wiki.) | Gate, password only (`one_factor`) | admin, family, friends |
| Seerr | No gate. Its only login is the Jellyfin one (local login off, `main.localLogin: false`), and Jellyfin checks the password against Authelia, so it is the Authelia password | Anyone with Jellyfin access (admin, family) |
| Jellyfin | No gate. Its own login form; a plugin checks the password against Authelia | admin, family |
| Open WebUI | OIDC ("Continue with Authelia"); the account is created as a normal *user*. Its *Deep Research* model (admins) uses Local Deep Research with a service account, so LDR needs no login of its own | admin, family, friends |
| Kavita | OIDC with auto-login (client `kavita`, policy `media`). The first login creates the account with roles Login, Bookmark, Download and the shared `Books` library. Authelia shows a consent screen on each fresh login, because Kavita always requests `offline_access` | admin, family |
| Actual | OIDC (client `actual-budget`, policy `admin_only`). `ACTUAL_USER_CREATION_MODE=login` creates the Actual user on the first login (role *basic*); share budget files with them in Actual | admin |

A **gate** is one line in an NPM host's Advanced config: `include /snippets/authelia.conf;`
([snippet](nginx-proxy-manager/snippets/authelia.conf)). It sends visitors to the login page;
`access_control` in `authelia/configuration.yml` decides who gets through.

Why:
- **Bindery must always have the gate.** It trusts the `Remote-User` header. Without the gate, a
  visitor could send any user name.
- **The download clients have no `/api` exception.** The *arr apps reach them inside Docker, so
  nothing outside needs their API.
- **Jellyfin has no gate.** TV and phone apps cannot show a web login page.
- **Seerr has no gate.** Its Jellyfin login already uses the Authelia password; a gate would add a second login page.
- **Open WebUI does not link accounts by email.** Signup does not verify emails, so somebody could
  sign up with your address and take over your account.

If Authelia is down: Open WebUI has a password login at `/auth?form=1`, Kavita at
`/login?skipAutoLogin=true`, and `authelia/jellyfin-breakglass.sh` gives your Jellyfin user a local
password again.

## Secrets

All secrets are in `~/HomeLab/.env` (mode `600`, not in git). [.env.example](.env.example) lists each
variable. A container gets only the variables in its own `environment:` block.

Other secret files, also only on the server: `authelia/configuration.yml`,
`authelia/users/auth_file.yml`, `signup/smtp.env`, and Kavita's `appsettings.json` (OIDC secret).
Open WebUI's database holds a copy of `DEEP_RESEARCH_PASSWORD` in the Deep Research function's valves.

Hermes cannot read `.env`. Before Hermes starts, `hermes-env.service` copies its two keys into the
root-only file `/run/hermes-gateway.env` (install: `sudo bash systemd/install-hermes-env.sh`). The
`hermes` user is not in the `docker` group, because that group gives root access.

To change a secret:
1. Edit the value in `.env` (no quotes).
2. Run `docker compose up -d <service>` for each service that uses it.
3. For `COREWEAVE_API_KEY` or `HERMES_API_KEY`: also `sudo systemctl restart hermes-gateway`.
4. For `GMAIL_APP_PASSWORD`: also `python3 signup/extract_smtp.py && docker compose up -d signup`.

## Downloads

| Client | How it connects | Used by |
|---|---|---|
| SABnzbd | Directly. Finished files go to `/media/usenet/complete/<category>` | Sonarr, Radarr, Lidarr, Bindery (`books`) |
| qBittorrent | Inside the `vpn` container (gluetun, ProtonVPN WireGuard, Amsterdam, forwarded port), so all torrent traffic uses the VPN. Saves to `/downloads/<category>` | Sonarr, Radarr, Lidarr, Bindery (`books` → `/downloads/books`) |
| slskd | Same VPN namespace, web UI at `vpn-gateway:5030` | Lidarr (Soulseek plugin) |

Prowlarr holds the indexers and syncs them to the *arr apps; Bindery pulls them from Prowlarr
(`Settings → Prowlarr`). Bindery's root folders are `/media/Books` (served by Kavita) and `/media/Audiobooks`.

| Symptom | Cause | Fix |
|---|---|---|
| All torrents stay at "downloading metadata", but the VPN has web access | The VPN server does not allow P2P (for example New York) | Keep `SERVER_CITIES` on a P2P city. We use Amsterdam |
| Seeds are visible, but 0 B/s | qBittorrent is still bound to `lo` after a VPN drop | The VPN up-command fixes this by itself. Check `/api/v2/app/preferences`: `current_network_interface` must be `""` |
| One magnet stays at "downloading metadata" for 10+ minutes | DHT through the VPN is unreliable | Get the file with `curl -A "Mozilla/5.0" -o /tmp/x.torrent "https://itorrents.org/torrent/<INFOHASH>.torrent"` and add it to qBittorrent (category `tv-sonarr`). Sonarr and Radarr are not affected |
| Every download tops out around 10–14 MB/s | The server's Wi-Fi link (~110 Mbit/s measured), not the apps | Use the cable: `server/setup-wired.sh` (see [Network](#network)) |

## Network

| Item | Value |
|---|---|
| Internet | Verizon Fios through a GPON SFP stick in the router (no Verizon ONT or router) |
| Router | Banana Pi BPI-R4, OpenWrt 25.12, 192.168.4.1. Away: `ssh -L 8443:192.168.4.1:443 fernando@ftoralesacosta.me`, then https://localhost:8443 |
| Server | 192.168.4.51 (DHCP reservation) on Wi-Fi `wlp130s0`. The wired ports (`enp129s0`, `eno0`) are not cabled yet; [server/setup-wired.sh](server/setup-wired.sh) makes the cable primary and keeps Wi-Fi as backup |
| Port forwards | TCP 22 (SSH), 80 + 443 (NPM), 25565 (Minecraft) |
| DNS | Subdomains go through the Cloudflare proxy. `ftoralesacosta.me` and `mc.` are DNS-only, because Minecraft is not HTTP. `cloudflare-ddns` keeps `@`, `mc.` and `wiki.` current |
| Jellyfin at home | The router's DNS sends `jellyfin.ftoralesacosta.me` to 192.168.4.51, so media stays on the LAN |
| Disks | `/` 256 GB NVMe (OS) · `/mnt/data` 2 TB NVMe (downloads, backups, Kiwix) · `/mnt/media` 14 TB HDD (media library) |

Security: SSH accepts keys only, with no root login. fail2ban bans repeated failures (never the LAN).
Debian security updates install automatically, without reboots. Other updates are manual.

## Other documents

- [authelia/README.md](authelia/README.md): users, groups, 2FA, OIDC apps
- [backup/README.md](backup/README.md): nightly backup to the second NVMe and Google Drive, and restore
- [ActualBudget/README.md](ActualBudget/README.md): budget jobs, receipt pages, scripts
- [kiwix/README.md](kiwix/README.md): offline Wikipedia, content and updates
- [local-deep-research/README.md](local-deep-research/README.md): research engine, service account, model choice
- [open-webui/functions/README.md](open-webui/functions/README.md): the Deep Research model (Open WebUI function), valves
- [HomeAssistant/README.md](HomeAssistant/README.md): config files, debug logging
- [OpenWRT-BPI_R4/README.md](OpenWRT-BPI_R4/README.md): router, fiber stick, recovery
