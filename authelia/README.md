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

Add a user:
1. Hash a password (a random one is fine; the user sets their own with **Reset password**):
   ```bash
   docker run --rm ghcr.io/authelia/authelia:4.39 authelia crypto hash generate argon2 --password '<password>'
   ```
2. Append under `users:` in `auth_file.yml`:
   ```yaml
       username:
           password: "$argon2id$..."
           displayname: First Last
           email: someone@example.com
           groups: []
           disabled: false
   ```
3. `docker restart authelia`
4. Tell them: open the app → **Continue with Authelia** → **Reset password?** → enter their email.

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
