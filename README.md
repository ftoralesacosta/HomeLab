# HomeLab

This repo is the configuration for my home server, `debian` (192.168.4.51). Most services run in one
Docker Compose stack. The repo also holds the host setup around it: Hermes, the router, backups
and hardening. The domain is `ftoralesacosta.me`, and its DNS is on Cloudflare.

```
Verizon fiber ─► BPI-R4 router (OpenWrt) ─► LAN 192.168.4.0/22 ─► debian
                 forwards TCP 22, 80, 443, 25565 ───────────────► debian
```

## Services

Each web app has its own subdomain, for example `sonarr.ftoralesacosta.me`.

| Area | Services |
|---|---|
| Edge | `reverse-proxy`: Nginx Proxy Manager (NPM) on 80/443, admin UI on port 81 (LAN only). `cloudflare-ddns`: keeps `ftoralesacosta.me` and `mc.` on the home IP |
| Login | `authelia` (auth.): single sign-on and 2FA. `signup` (signup.): public form to request an account |
| AI | `open-webui` (webui.), `searxng` (web search, LAN only). Hermes agent: systemd service `hermes-gateway`, not Docker, API on 127.0.0.1:8642 |
| Media | `jellyfin` (player). `sonarr`, `radarr`, `lidarr` (TV, movies, music), `prowlarr` + `flaresolverr` (indexers), `bazarr` (subtitles), `seerr` (family requests). `bindery` + `kavita` (books: download + read) |
| Downloads | `sabnzbd` (usenet), `qbittorrent` (torrents, through the `vpn` container) |
| Home | `homeassistant` (ha.), `homebridge` |
| Other | `actual` + `actual-ai` (budget.), `mc` (Minecraft, port 25565), `website` (ftoralesacosta.me) |

## Daily operations

Run the commands in `~/HomeLab`.

| Task | Command |
|---|---|
| Start or update one service | `docker compose up -d <service>` |
| Get a newer image | `docker compose pull <service> && docker compose up -d <service>` |
| Add a subdomain | `nginx-proxy-manager/add-host.sh <name>.ftoralesacosta.me <container>:<port> [--authelia]` |
| Add a user | `authelia/add-user.sh <user> <email> "<Name>" <group>` |
| Approve a signup | `authelia/approve-user.sh <user> [family\|friends]` |
| Harden a fresh install | `sudo bash server/harden-host.sh` |

- Change one service at a time. Do not restart the full stack.
- Do not use `docker compose down -v` or prune volumes. That deletes app data.
- Proxy hosts are in NPM's database, not in this repo. Use `add-host.sh` or the NPM UI.
- NPM UI: http://192.168.4.51:81 at home. Away: `ssh -L 8181:localhost:81 fernando@ftoralesacosta.me`,
  then http://localhost:8181.

## Secrets

All secrets are in `~/HomeLab/.env` (mode `600`, not in git). [.env.example](.env.example) lists each
variable. A container gets only the variables in its own `environment:` block.

Other secret files, also only on the server: `authelia/configuration.yml`,
`authelia/users/auth_file.yml`, `signup/smtp.env`.

Hermes cannot read `.env`. Before Hermes starts, `hermes-env.service` copies its two keys into the
root-only file `/run/hermes-gateway.env` (install: `sudo bash systemd/install-hermes-env.sh`). The
`hermes` user is not in the `docker` group, because that group gives root access.

To change a secret:
1. Edit the value in `.env` (no quotes).
2. Run `docker compose up -d <service>` for each service that uses it.
3. For `COREWEAVE_API_KEY` or `HERMES_API_KEY`: also `sudo systemctl restart hermes-gateway`.
4. For `GMAIL_APP_PASSWORD`: also `python3 signup/extract_smtp.py && docker compose up -d signup`.

## Login and access (Authelia)

https://auth.ftoralesacosta.me is the login for most apps. One login covers all subdomains, and
gated apps need a second factor (TOTP or security key). Details: [authelia/README.md](authelia/README.md).

| Group | Access |
|---|---|
| `admin` | Everything |
| `family` | Media apps and Open WebUI |
| `friends` | Open WebUI only |
| `pending` | Nothing. New signups wait here until I approve them |

| App | How it logs in | Who |
|---|---|---|
| Home Assistant | Gate (the companion app uses HA tokens on `/api/` and `/auth/token`) | admin |
| SABnzbd, qBittorrent | Gate | admin |
| *arr apps, Seerr | Gate. `/api` skips the gate for API-key clients | admin, family |
| Bazarr | Gate, plus its own login | admin, family |
| Bindery | Gate. Bindery takes the user name from the gate | admin, family |
| Open WebUI | OIDC ("Continue with Authelia"), then I approve the account | admin, family, friends |
| Jellyfin | Its own login form; a plugin checks the password against Authelia | admin, family |
| Kavita, Actual | Their own login | — |

A **gate** is one line in an NPM host's Advanced config: `include /snippets/authelia.conf;`.
It sends visitors to the login page. `access_control` in `authelia/configuration.yml` decides who
gets through.

Why:
- **Bindery must always have the gate.** It trusts the `Remote-User` header. Without the gate, a
  visitor could send any user name.
- **The download clients have no `/api` exception.** The *arr apps reach them inside Docker, so
  nothing outside needs their API.
- **Jellyfin has no gate.** TV and phone apps cannot show a web login page.
- **Open WebUI does not link accounts by email.** Signup does not verify emails, so somebody could
  sign up with your address and take over your account.

If Authelia is down: Open WebUI has a password login at `/auth?form=1`, and
`authelia/jellyfin-breakglass.sh` gives your Jellyfin user a local password again.

## Downloads

SABnzbd connects directly. qBittorrent shares the network of the `vpn` container (gluetun,
ProtonVPN WireGuard), so all torrent traffic goes through the VPN.

| Symptom | Cause | Fix |
|---|---|---|
| All torrents stay at "downloading metadata", but the VPN has web access | The VPN server does not allow P2P (for example New York) | Keep `SERVER_CITIES` on a P2P city. We use Amsterdam |
| Seeds are visible, but 0 B/s | qBittorrent is still bound to `lo` after a VPN drop | The VPN up-command fixes this by itself. Check `/api/v2/app/preferences`: `current_network_interface` must be `""` |
| One magnet stays at "downloading metadata" for 10+ minutes | DHT through the VPN is unreliable | Get the file with `curl -A "Mozilla/5.0" -o /tmp/x.torrent "https://itorrents.org/torrent/<INFOHASH>.torrent"` and add it to qBittorrent (category `tv-sonarr`). Sonarr and Radarr are not affected |

## Network

| Item | Value |
|---|---|
| Internet | Verizon Fios through a GPON SFP stick in the router (no Verizon ONT or router) |
| Router | Banana Pi BPI-R4, OpenWrt 25.12, 192.168.4.1. Away: `ssh -L 8443:192.168.4.1:443 fernando@ftoralesacosta.me`, then https://localhost:8443 |
| Server | 192.168.4.51 (DHCP reservation), Wi-Fi `wlp130s0` |
| Port forwards | TCP 22 (SSH), 80 + 443 (NPM), 25565 (Minecraft) |
| DNS | Subdomains go through the Cloudflare proxy. `ftoralesacosta.me` and `mc.` are DNS-only, because Minecraft is not HTTP |
| Jellyfin at home | The router's DNS sends `jellyfin.ftoralesacosta.me` to 192.168.4.51, so media stays on the LAN |

Security: SSH accepts keys only, with no root login. fail2ban bans repeated failures (never the LAN).
Debian security updates install automatically, without reboots. Other updates are manual.

## Other documents

- [authelia/README.md](authelia/README.md): users, groups, 2FA, OIDC apps
- [nginx-proxy-manager/README.md](nginx-proxy-manager/README.md): `add-host.sh`
- [backup/README.md](backup/README.md): nightly backup to the second NVMe and Google Drive, and restore
- [OpenWRT-BPI_R4/README.md](OpenWRT-BPI_R4/README.md): router, fiber stick, recovery
- [HomeAssistant/README.md](HomeAssistant/README.md), [ActualBudget/README.md](ActualBudget/README.md)
- [homelab-sso-rollout.md](homelab-sso-rollout.md): history of the Authelia rollout
