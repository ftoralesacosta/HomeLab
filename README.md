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
| Edge | `reverse-proxy` (Nginx Proxy Manager: 80/443, admin 81 LAN-only), `cloudflare-ddns`, `cloudflare-ddns-for-minecraft` |
| Auth | `authelia` (https://auth.ftoralesacosta.me, image pinned to 4.39) |
| AI | `open-webui` (https://webui.ftoralesacosta.me, host network, port 3000; web search via SearXNG), `searxng` (LAN only) |
| Media | `jellyfin`, `sonarr`, `radarr`, `prowlarr`, `bazarr`, `sabnzbd`, `qbittorrent` (via `vpn` = gluetun), `flaresolverr` |
| Home | `homeassistant`, `homebridge` |
| Other | `mc` (Minecraft), `actual` (Actual Budget), `portainer`, `website` |

Start / update: `docker compose up -d [service]` in this directory.

Not in this compose file:
- **Hermes agent**: systemd service `hermes-gateway` (user `hermes`, `/opt/hermes-agent`,
  API on 127.0.0.1:8642). Open WebUI uses it as a second model backend.
- **Codex CLI**: `~/.codex/config.toml`, provider `coreweave` (reads `COREWEAVE_API_KEY`).

---

## Secrets: one file, `.env`

All secrets live in **`~/HomeLab/.env`** (owner `fernando`, mode `600`, gitignored).
`.env.example` lists every variable with placeholders.

| Variable | Used by |
|---|---|
| `COREWEAVE_API_KEY`, `COREWEAVE_API_BASE` | Open WebUI, Hermes, Codex/shells |
| `HERMES_API_KEY` | Open WebUI (client) and Hermes (as `API_SERVER_KEY`) |
| `WEBUI_SECRET_KEY`, `OAUTH_CLIENT_SECRET` | Open WebUI |
| `GMAIL_APP_PASSWORD` | Authelia (email notifier) |
| `Cloudflare_API_KEY`, `WIREGUARD_*`, `SEARXNG_SECRET`, `DOMAIN_NAME`, `DOCKERDIR` | the containers that reference them in docker-compose.yml |

How each consumer gets its values:
- **Containers**: Compose substitutes `${VAR}` from `.env`. A container receives only the
  variables listed in its own `environment:` block, not the whole file.
- **Codex / shells**: `~/.bashrc` exports only `COREWEAVE_API_KEY` and `COREWEAVE_API_BASE`
  from `.env`.
- **Hermes**: the `hermes` user **cannot read `.env`**. `hermes-env.service` (runs as root just
  before Hermes) copies only `COREWEAVE_API_KEY` and `HERMES_API_KEY` (renamed to
  `API_SERVER_KEY`) into the root-only file `/run/hermes-gateway.env`, which systemd loads into
  Hermes. Files: [`systemd/`](systemd/). Install or reinstall:
  `sudo bash ~/HomeLab/systemd/install-hermes-env.sh`.
  The `hermes` user is deliberately **not** in the `docker` group (that group is root-equivalent)
  or the `fernando` group.

Other secret files (gitignored, real values only on the server):
`authelia/configuration.yml` (JWT/storage/OIDC secrets), `authelia/auth_file.yml` (users).

### Change the CoreWeave API key

1. Edit `COREWEAVE_API_KEY=` in `~/HomeLab/.env` (no quotes). Test it:
   `curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer <key>" https://api.inference.wandb.ai/v1/models` → `200`.
2. `cd ~/HomeLab && docker compose up -d open-webui`
3. `sudo systemctl restart hermes-gateway`
4. Open a new shell (Codex).

The same pattern applies to any other variable: edit `.env`, then `docker compose up -d <service>`
(and restart `hermes-gateway` if it is `HERMES_API_KEY`).

---

## Single sign-on (Authelia)

- Login page: https://auth.ftoralesacosta.me (users in `authelia/auth_file.yml`, see
  [authelia/README.md](authelia/README.md)). Session cookie covers all `*.ftoralesacosta.me`.
- **Open WebUI** uses Authelia as its OIDC provider ("Continue with Authelia"). Accounts are
  linked by email; new accounts via SSO are disabled (`ENABLE_OAUTH_SIGNUP=false`). The password
  form is still enabled (`ENABLE_LOGIN_FORM=false` would hide it).
- Adding an OIDC app: add a client under `identity_providers.oidc.clients` in
  `authelia/configuration.yml` (template in `configuration.example.yml`), restart `authelia`.
- **Jellyfin is intentionally not behind the Authelia gate**: the TV/phone apps (Swiftfin, etc.)
  cannot do a browser login. Planned: Jellyfin SSO plugin (OIDC) for the web login only; apps keep
  Jellyfin logins / Quick Connect.
- Plan and status of the wider rollout: [homelab-sso-rollout.md](homelab-sso-rollout.md).

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
