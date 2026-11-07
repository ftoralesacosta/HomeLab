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

## Two-Factor Authentication

Users in `admin`/`family` need a password **plus** a second factor on every gated app:
*arr, Bindery, Home Assistant, Jellyfin, and Open WebUI (OIDC client policy `two_factor`).
Friends (no group) are unaffected on Jellyfin and the portal (`one_factor`), but Open WebUI
now asks *everyone* for a second factor. Methods (enabled by default in 4.39; branding
`ftoralesacosta.me`):

- **TOTP** — any authenticator app (Aegis, Google Authenticator, 1Password, ...).
- **WebAuthn** — security keys or passkeys, registered as the *second* factor
  (passkey *login* stays off).

Enroll (once per user): log in at https://auth.ftoralesacosta.me → **Two-Factor
Authentication** → **Add TOTP** (scan the QR) and/or **Add Security Key**. A user who hits
a `two_factor` app with nothing registered is sent to enrollment automatically.

`identity_validation.elevated_session` (live config) hardens the portal: adding another
2FA device requires an existing second factor — a stolen password alone cannot register
an attacker's device. First-time enrollment still works (`skip_second_factor: true`).

Lost device — an admin deletes it and the user re-enrolls at next login:
```bash
docker exec authelia authelia storage user totp delete <username> --config /config/configuration.yml
docker exec authelia authelia storage user webauthn delete <username> --all --config /config/configuration.yml
```

## Apps

| App | How it uses Authelia |
|---|---|
| Open WebUI | **OIDC login** (client `open-webui`, policy `two_factor` — applies to all users, friends included). New Authelia users get a *pending* Open WebUI account that an admin approves |
| Jellyfin | Web login goes through the Authelia **gate** (`admin`+`family` → `two_factor`, any other user → `one_factor`), but there is no credential integration — Jellyfin's own login still applies. TV/phone apps cannot do a browser login; planned: Jellyfin SSO plugin (web login only) |
| Bindery | **Proxy SSO**: gate snippet forwards `Remote-User`; Bindery auth mode "proxy" (set via API, `PUT /api/v1/auth/mode`). Passing users log straight in; new usernames auto-provision as role `user`. Gate rule: groups `admin` + `family` |
| *arr (prowlarr/lidarr/sonarr/radarr) | **Gate + External auth**: gate snippet on all four hosts; apps run `AuthenticationMethod=External` (config.xml) so the gate login is the only login; Authelia bypasses `/api` + `/[0-9]+/api` for API-key clients; UI rule: `two_factor`, groups `admin` + `family` |
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
