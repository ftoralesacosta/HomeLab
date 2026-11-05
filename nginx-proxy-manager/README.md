# Nginx Proxy Manager

Edge reverse proxy (container `reverse-proxy`, image `jc21/nginx-proxy-manager`): ports `80`/`443`,
TLS via Let's Encrypt, proxy hosts for `*.ftoralesacosta.me`. The admin UI is LAN-only at
http://192.168.4.51:81 (away: `ssh -L 8181:localhost:81 fernando@ftoralesacosta.me`).

Proxy hosts live in NPM's own database (`${DOCKERDIR}/nginx-proxy-manager/data`), **not** in this
repo. Manage them from the UI or with the CLI below — the CLI uses the same REST API as the UI.

## Files

| File | In git | Contents |
|---|---|---|
| `add-host.sh` | yes | CLI for proxy hosts (see below) |
| `snippets/authelia.conf` | yes | Authelia gate snippet, mounted read-only at `/snippets` in the container |

## add-host.sh — manage proxy hosts from the shell

Login: `NPM_ADMIN_EMAIL` from `../.env`. The password is **prompted with hidden input and
never stored** — `NPM_ADMIN_PASSWORD` in the environment or `../.env` is only for
non-interactive/scripted use. A fresh login token is used per run; nothing is cached.
See `--help` for all options.

```bash
./add-host.sh --list                                            # all hosts: forward, SSL, gate
./add-host.sh lidarr.ftoralesacosta.me lidarr:8686             # create with Let's Encrypt
./add-host.sh bindery.ftoralesacosta.me bindery:8787 --authelia  # create behind the SSO gate
./add-host.sh new.ftoralesacosta.me service:1234 --cert 7     # create, reuse the wildcard cert
./add-host.sh books.example.com bindery:8787 --authelia --dry-run  # show payloads, change nothing
./add-host.sh kavita.ftoralesacosta.me kavita:5000 --update    # update existing (keeps its cert)
./add-host.sh --delete test.example.com                         # prompts; -y skips
```

Defaults: **SSL on** (Force SSL), WebSockets on, HTTP/2 on, Block Common Exploits on.
Certificates: an existing NPM certificate covering the domain is **reused automatically** — all
hosts in this stack share the wildcard `*.ftoralesacosta.me` (cert 7), so new hosts pick it up
with no extra flags. `--cert <id>` pins a specific certificate, `--new-cert` requests a dedicated
Let's Encrypt one instead (create only), `--no-ssl` skips SSL for quick LAN-only tests.
`--update` treats the flags as the source of truth but always keeps an attached certificate
(`--cert` on an update overrides it); without it an existing domain is an error.

Forward to the **container name** (`lidarr`, `bindery`, ...) — NPM shares `proxy-net` with the
stack. Wildcard domains (`*.ftoralesacosta.me`) must use DNS challenges, which this CLI does
not manage — create those in the UI.

### Gated hosts (`--authelia`)

Only adds `include /snippets/authelia.conf;` to the host's Advanced config: visitors are
redirected to the Authelia login. Who may pass is set by `access_control` in
`authelia/configuration.yml` — add a rule and `docker restart authelia`. Apps that consume the
forwarded `Remote-User` (Bindery) **must** never be routed without the snippet; see
[snippets/authelia.conf](snippets/authelia.conf) and the SSO section in [../README.md](../README.md).

### SSL notes

- New certs: Let's Encrypt HTTP-01 — the domain's DNS must point here and ports 80/443 must
  reach NPM (port-forwarded; Cloudflare proxy must be off for the challenge).
- The issue waits ~90 s for validation, then returns; NPM finishes in the background either way.
  Pending/failed: `docker exec nginx-proxy-manager tail -n 30 /data/logs/letsencrypt.log`.
- NPM < 2.13 (this stack) needs the LE "agree" meta on cert requests — the CLI detects the
  version and handles both shapes.

### Troubleshooting

- `NPM login failed (HTTP 401)` — wrong `NPM_ADMIN_EMAIL` in `../.env` or mistyped password.
- `create failed (HTTP 400)` — usually a duplicate domain or invalid forward host.
- Host created but site is 502 — wrong forward host/port or the target is not on `proxy-net`.
