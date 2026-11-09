# HomeLab

Docker Compose stack on the Debian server (`debian`, 192.168.4.51), plus the host-level pieces
around it (Hermes agent, router). Public domain: `ftoralesacosta.me` (Cloudflare).

```
Verizon fiber ─► BPI-R4 router (OpenWrt) ─► LAN 192.168.4.0/22 ─► debian (this repo)
                 ports 22/80/443/25565 ─────────────────────────► debian
```

## Services (docker-compose.yml)

| Area | Services |
|---|---|
| Edge | `reverse-proxy` (Nginx Proxy Manager: 80/443; admin UI **not public**: http://192.168.4.51:81 at home, away `ssh -L 8181:localhost:81 fernando@ftoralesacosta.me` → http://localhost:8181), `cloudflare-ddns` (favonia; one container updates the DNS-only `ftoralesacosta.me` + `mc.` records) |
| Auth | `authelia` (https://auth.ftoralesacosta.me, image pinned to 4.39), `signup` (https://signup.ftoralesacosta.me, self-service → `pending`) |
| AI | `open-webui` (https://webui.ftoralesacosta.me, host network, port 3000; web search via SearXNG), `searxng` (LAN only) |
| Media | `jellyfin`, `sonarr`, `radarr`, `lidarr` (music), `bazarr`, `prowlarr`, `sabnzbd`, `qbittorrent` (via `vpn` = gluetun), `flaresolverr`, `bindery` (books, Readarr successor), `kavita` (ebook/comic reader), `seerr` (request manager, Overseerr successor) |
| Home | `homeassistant`, `homebridge` |
| Other | `mc` (Minecraft), `actual` (Actual Budget), `website` |

Start / update: `docker compose up -d [service]` in this directory.

Proxy hosts (`*.ftoralesacosta.me` → containers) live in NPM's database, not in this repo —
manage them in the UI (http://192.168.4.51:81) or with
[`nginx-proxy-manager/add-host.sh`](nginx-proxy-manager/README.md).

Not in this compose file:
- **Hermes agent**: systemd service `hermes-gateway` (user `hermes`, `/opt/hermes-agent`,
  API on 127.0.0.1:8642). Open WebUI uses it as a second model backend.

---

## Secrets: one file, `.env`

All secrets live in **`~/HomeLab/.env`** (owner `fernando`, mode `600`, gitignored).
`.env.example` lists every variable with placeholders.

| Variable | Used by |
|---|---|
| `COREWEAVE_API_KEY`, `COREWEAVE_API_BASE` | Open WebUI, Hermes, shells |
| `HERMES_API_KEY` | Open WebUI (client) and Hermes (as `API_SERVER_KEY`) |
| `WEBUI_SECRET_KEY`, `OAUTH_CLIENT_SECRET` | Open WebUI |
| `GMAIL_APP_PASSWORD` | Authelia (email notifier) |
| `NPM_ADMIN_EMAIL` | `nginx-proxy-manager/add-host.sh` CLI (admin password is prompted, never stored) |
| `Cloudflare_API_KEY`, `WIREGUARD_*`, `SEARXNG_SECRET`, `DOMAIN_NAME`, `DOCKERDIR` | the containers that reference them in docker-compose.yml |

How each consumer gets its values:
- **Containers**: Compose substitutes `${VAR}` from `.env`. A container receives only the
  variables listed in its own `environment:` block, not the whole file.
- **Shells**: `~/.bashrc` exports only `COREWEAVE_API_KEY`, `COREWEAVE_API_BASE`, and `HERMES_API_KEY`
  from `.env`.
- **Hermes**: the `hermes` user **cannot read `.env`**. `hermes-env.service` (runs as root just
  before Hermes) copies only `COREWEAVE_API_KEY` and `HERMES_API_KEY` (renamed to
  `API_SERVER_KEY`) into the root-only file `/run/hermes-gateway.env`, which systemd loads into
  Hermes. Files: [`systemd/`](systemd/). Install or reinstall:
  `sudo bash ~/HomeLab/systemd/install-hermes-env.sh`.
  The `hermes` user is deliberately **not** in the `docker` group (that group is root-equivalent)
  or the `fernando` group.

Other secret files (gitignored, real values only on the server):
`authelia/configuration.yml` (JWT/storage/OIDC secrets), `authelia/users/auth_file.yml` (users),
`signup/smtp.env`.

### Change the CoreWeave API key

1. Edit `COREWEAVE_API_KEY=` in `~/HomeLab/.env` (no quotes). Test it:
   `curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer <key>" https://api.inference.wandb.ai/v1/models` → `200`.
2. `cd ~/HomeLab && docker compose up -d open-webui`
3. `sudo systemctl restart hermes-gateway`

The same pattern applies to any other variable: edit `.env`, then `docker compose up -d <service>`
(and restart `hermes-gateway` if it is `HERMES_API_KEY`).

---

## Single sign-on (Authelia)

- Login page: https://auth.ftoralesacosta.me (users in `authelia/users/auth_file.yml`, see
  [authelia/README.md](authelia/README.md)). Session cookie covers all `*.ftoralesacosta.me`.
- **Open WebUI** uses Authelia as its OIDC provider and redirects straight to the Authelia login
  (`OAUTH_AUTO_REDIRECT=true`, `ENABLE_LOGIN_FORM=false`). Only groups admin/family/friends may
  complete the OIDC login (Authelia policy `approved`); new users get a *pending* Open WebUI account
  that an admin approves. Accounts are **not** merged by email (signup emails are unverified). **If Authelia is down**: password login still works at
  https://webui.ftoralesacosta.me/auth?form=1 (Open WebUI email + password).
- Adding an OIDC app: add a client under `identity_providers.oidc.clients` in
  `authelia/configuration.yml` (template in `configuration.example.yml`), restart `authelia`.
- **Authelia gate** (NPM host → Advanced: `include /snippets/authelia.conf;`, file
  `nginx-proxy-manager/snippets/authelia.conf`; the snippet also forwards the
  authenticated username as `Remote-User`): `ha.` (group `admin` only; HA `/api/` and
  `/auth/token` bypass so the companion app works), and
  `bindery.` (groups `admin` + `family`; Bindery runs auth mode "proxy" and consumes
`Remote-User`, so a passing Authelia session logs straight in — no second login; other
   Authelia users auto-provision as role `user`), the *arr stack (groups `admin` + `family`,
   `/api` bypassed for API-key clients), `seerr.` (same shape as the *arr rule), `bazarr.`
   (admin + family), and the download clients `sabnzbd.` + `qbittorrent.` (admin only, no
   bypass — internal clients use the container names). Never
   route to Bindery from an NPM
  host/location without the snippet — a client could forge the identity header. Who may
  pass is set by `access_control` in `authelia/configuration.yml`.
- **Jellyfin auth (2026-11-08)**: no gate — the login page is public and credentials
  are Authelia's. The Authelia-Auth plugin validates the form/API (Finamp, Apple TV)
  against Authelia 1FA and auto-creates users (admin from the `admin` group; grant
  libraries once per new user). An OIDC "Sign in with SSO" door (SSO-Auth plugin +
  its Authelia client) was tried and removed the same day — the form is the login, 1FA.
  TV/phone: use the public `https://jellyfin.ftoralesacosta.me` (NAT hairpin verified
  from the LAN) with the same Authelia username+password.
  Break-glass if Authelia is down: `authelia/jellyfin-breakglass.sh`.
- Plan and status of the wider rollout: [homelab-sso-rollout.md](homelab-sso-rollout.md).

---

## Downloads: *arrs, usenet, torrents

Two transports, deliberately split:
- **SABnzbd** (usenet) — direct internet, no VPN. Categories: `tv`, `audio` (Lidarr), etc.
- **qBittorrent** (torrents) — network-shared with `vpn` (gluetun → ProtonVPN WireGuard),
  category `tv-sonarr`. All torrent traffic traverses the tunnel.

### VPN exit must be a P2P-enabled city

ProtonVPN only allows BitTorrent on P2P-marked servers. **US exits (e.g. New York) are not
P2P-enabled** and silently black-hole tracker/peer/DHT traffic while plain web (80/443)
keeps working. Symptom: every torrent sits at `metaDL` ("qBittorrent is downloading
metadata") at 0 B/s forever, trackers show "skipping tracker announce (unreachable)",
while `docker exec vpn-gateway wget -qO- https://ipinfo.io/ip` succeeds.
`SERVER_CITIES` in compose stays on a P2P city — **Amsterdam** (Proton's main P2P hub).

### qB loopback-bind trap (self-healing since Nov 2026)

The NAT-PMP **down**-command sets qB's `current_network_interface: "lo"` as a kill switch
when the tunnel drops. The **up**-command used to restore only `listen_port`, so after any
VPN blip qB stayed bound to loopback indefinitely: seeds visible in tracker lists, 58
"connected" peers, 0 bytes — with the tunnel itself tested fine. The up-command now also
clears `current_network_interface` / `current_interface_address`, making the kill switch
self-healing. If torrents ever show seeds but 0 B/s again:
`GET /api/v2/app/preferences` → `current_network_interface` should be `""`, not `lo`.

### Magnet metadata stalling

DHT metadata resolution through the tunnel is unreliable: a magnet from a healthy swarm
can sit at `metaDL` indefinitely. If it hasn't resolved in ~10 min, inject the `.torrent`
file — itorrents.org mirrors by infohash and qB merges it into the existing entry (same
infohash, so Sonarr/Radarr tracking is unaffected):

```sh
curl -A "Mozilla/5.0" -o /tmp/x.torrent "https://itorrents.org/torrent/<INFOHASH>.torrent"
# then add to qB via torrents/add (multipart, category tv-sonarr)
```

---

## Network

| Item | Value |
|---|---|
| Router | Banana Pi BPI-R4, official OpenWrt 25.12, LAN gateway **192.168.4.1** (web UI http://192.168.4.1, LAN only); see [OpenWRT-BPI_R4/](OpenWRT-BPI_R4/README.md) |
| Internet | Verizon Fios via a GPON SFP stick in the router (no Verizon ONT/router) |
| Server | `debian` = **192.168.4.51** (DHCP reservation), Wi-Fi `wlp130s0` |
| Port forwards → 192.168.4.51 | TCP 22 (SSH), 80 + 443 (Nginx Proxy Manager), 25565 (Minecraft) |
| Public IP | dynamic; `cloudflare-ddns*` containers update `ftoralesacosta.me` and `mc.` within ~5 min |
| Remote router access | SSH tunnel: `ssh -L 8443:192.168.4.1:443 fernando@ftoralesacosta.me`, then https://localhost:8443 |

Hard-coded LAN addresses in this repo: SearXNG binds `127.0.0.1:8888` (Open WebUI web search,
Hermes) and `192.168.4.51:8888` (LAN browser access). NPM host `ha` → `192.168.4.51:8123`.

Router setup (OpenWrt, GPON fiber stick, patches, recovery): [OpenWRT-BPI_R4/](OpenWRT-BPI_R4/README.md).

Backups (nightly restic → 2nd NVMe + Google Drive, restore steps): [backup/README.md](backup/README.md).
