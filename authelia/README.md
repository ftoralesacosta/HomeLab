# Authelia

SSO front for the homelab. Runs on `proxy-net` (NPM reaches it at `authelia:9091`),
loopback-mapped to `127.0.0.1:9091` for pre-NPM testing, and will be served at
`https://auth.ftoralesacosta.me` through nginx-proxy-manager.

## Files

| File | Tracked? | Notes |
| --- | --- | --- |
| `configuration.yml` | no (gitignored) | Real secrets (`jwt_secret`, `secret`) |
| `auth_file.yml` | no (gitignored) | Users + bcrypt hashes |
| `configuration.example.yml` | yes | Template |
| `auth_file.example.yml` | yes | Template |

SQLite DB (sessions, TOTP seeds, WebAuthn credentials) lives in
`${DOCKERDIR}/authelia/data` — back that up.

## Adding / changing users (multi-user)

1. Generate a bcrypt hash for the chosen password:

   ```bash
   python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_BLOWFISH)))" 'their-password'
   ```

2. Add the user under `users:` in `auth_file.yml` (v4.38+ format: the username
   is the key; value has displayname, password hash, email, groups).
   `admin` gets full privileges; use `family` for regular members.
3. Restart so it picks up the file:

   ```bash
   docker compose -f ~/HomeLab/docker-compose.yml restart authelia
   ```

Users can also change their own password from the profile page after logging in
(file backend rewrites the hash in `auth_file.yml`).

Note on file format (4.39): when a password is changed in the UI, Authelia
rewrites the whole file in its expanded form (all OIDC claim fields spelled
out) and re-hashes the password to argon2id, dropping comments and the
top-level `groups` list. This is expected — hand-edit minimal entries as
shown above; don't fight the app's formatting.

## Protecting services

nginx-proxy-manager has a built-in **Authelia** authentication method:

1. NPM UI → Access Lists → add one named e.g. `authelia`, authentication
   `Authelia`, server URL `https://auth.ftoralesacosta.me`.
2. Select that access list on these hosts (final scope, 2026-10-20):
   jellyfin, ha, webui, portainer, nginx (the NPM UI itself), and `search`
   (searxng) once it exists.

Browsers/apps are bounced to `auth.ftoralesacosta.me`, log in once, and the
session cookie (domain `ftoralesacosta.me`) covers every subdomain. For these
apps the own login still appears behind the gate — the gate is defense-in-depth,
not SSO. The seamless single login comes from OIDC (see
`../homelab-sso-rollout.md`, section 4), which these apps all support.

**Never gated:**

- the apex website (`ftoralesacosta.me`) — it is public;
- `budget` (Actual) — desktop/mobile clients sync straight to its API with
  only the server password and cannot present an Authelia token; gating it
  would hard-break remote sync;
- the arr stack (radarr, sonarr, prowlarr, sabnzbd, qbittorrent, bazarr) —
  decided to keep their own logins (strong unique passwords) instead of a
  double login.

See `../homelab-sso-rollout.md` for the full plan, including optional OIDC
SSO on top of the gate.
