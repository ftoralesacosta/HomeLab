# Authelia

Login portal and OIDC provider for the homelab: https://auth.ftoralesacosta.me
(container `authelia`, image pinned to `4.39`, on `proxy-net`; NPM reaches it at `authelia:9091`).

## Files

| File | In git | Contents |
|---|---|---|
| `configuration.yml` | no (gitignored) | Real config + secrets (JWT, storage key, OIDC key/HMAC/client digests) |
| `auth_file.yml` | no (gitignored) | Users and password hashes |
| `configuration.example.yml` | yes | Same structure with placeholders |
| `auth_file.example.yml` | yes | User template |

Sessions, TOTP and WebAuthn data: `${DOCKERDIR}/authelia/data` (SQLite) — include it in backups.
Email (password reset, 2FA setup) is sent from Gmail; the app password is `GMAIL_APP_PASSWORD` in `../.env`.

## Users

Current groups: `admin` (you), `family`. Friends get **no group** (no admin rights).

Add a user (one command; creates the account with a random password and restarts Authelia):
```bash
~/HomeLab/authelia/add-user.sh jane jane@example.com "Jane Doe"            # friend: no group
~/HomeLab/authelia/add-user.sh --dry-run jane jane@example.com "Jane Doe"  # preview only
```
It prints the message to send them. They open the app → **Continue with Authelia** → **Reset password?**
(username or email; link valid 30 min) → log in → accept the consent screen. Then approve them in
Open WebUI: **Admin Panel → Users** → role *pending* → **user**.

Disable a user: set `disabled: true`, restart. Authelia rewrites `auth_file.yml` in an expanded format when
someone changes a password; that is expected.

## Apps

| App | How it uses Authelia |
|---|---|
| Open WebUI | **OIDC login** (client `open-webui`). New Authelia users get a *pending* Open WebUI account that an admin approves |
| Jellyfin | Not connected: TV/phone apps cannot do a browser login. Planned: Jellyfin SSO plugin (web login only) |
| Others | Own logins. NPM can add an Authelia **gate** per host (Access Lists → method *Authelia*) |

Add an OIDC app: add a client under `identity_providers.oidc.clients` in `configuration.yml` (template in
`configuration.example.yml`; secrets with `authelia crypto rand` / `authelia crypto hash generate pbkdf2`),
then check and restart:
```bash
docker run --rm -e AUTHELIA_NOTIFIER_SMTP_PASSWORD=x -v $PWD/configuration.yml:/config/configuration.yml:ro \
  -v $PWD/auth_file.yml:/config/auth_file.yml:ro ghcr.io/authelia/authelia:4.39 \
  authelia validate-config --config /config/configuration.yml
docker restart authelia
```

Plan and history: [`../homelab-sso-rollout.md`](../homelab-sso-rollout.md).
