# Authelia

Login portal and OIDC provider for the homelab: https://auth.ftoralesacosta.me
(container `authelia`, image pinned to `4.39`, runs as uid 1000, on `proxy-net`; NPM reaches it at
`authelia:9091`, no host port).

## Files

| File | In git | Contents |
|---|---|---|
| `configuration.yml` | no (gitignored) | Real config + secrets (JWT, storage key, OIDC key/HMAC/client digests) |
| `users/auth_file.yml` | no (gitignored) | Users and password hashes. Mounted as a **directory** (`users/`) so `file.watch` sees changes: edits reload live, no restart |
| `configuration.example.yml` | yes | Same structure with placeholders |
| `auth_file.example.yml` | yes | User template |

Sessions, TOTP and WebAuthn data: `${DOCKERDIR}/authelia/data` (SQLite) — include it in backups.
Email (password reset, 2FA setup) is sent from Gmail; the app password is `GMAIL_APP_PASSWORD` in `../.env`.

## Users

| Group | Gets |
|---|---|
| `admin` | everything (HA, download clients, *arr, Bindery, Seerr, Jellyfin admin, Open WebUI) |
| `family` | *arr, Bazarr, Bindery, Seerr, Jellyfin, Open WebUI |
| `friends` | Open WebUI only |
| `pending` | portal only (self-service signups awaiting approval) |
| *(none)* | portal only |

Add a user (one command; random password, Authelia reloads the file by itself):
```bash
~/HomeLab/authelia/add-user.sh jane jane@example.com "Jane Doe" friends    # Open WebUI only
~/HomeLab/authelia/add-user.sh --dry-run jane jane@example.com "Jane Doe"  # preview only
```
Self-service signups (https://signup.ftoralesacosta.me) land in `pending`; approve with
`approve-user.sh <user> [family|friends]`. Signup emails are **not verified** — check the
approval email before approving.
It prints the message to send them. They open the app → **Continue with Authelia** → **Reset password?**
(username or email; link valid 30 min) → log in → accept the consent screen. Then approve them in
Open WebUI: **Admin Panel → Users** → role *pending* → **user**.

Disable a user: set `disabled: true` in `users/auth_file.yml` (reloads live). Authelia rewrites `auth_file.yml` in an expanded format when
someone changes a password; that is expected.

## Two-Factor Authentication

Users in `admin`/`family` need a password **plus** a second factor on every gated app:
*arr, Bazarr, SABnzbd, qBittorrent, Bindery, Seerr, Home Assistant, and Open WebUI
(OIDC authorization policy `approved`: two_factor for admin/family/friends, everyone else
denied). The portal itself is `one_factor`. Methods (enabled by default in 4.39; branding
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
| Open WebUI | **OIDC login** (client `open-webui`, authorization policy `approved`: groups admin/family/friends, 2FA; `pending`/no-group users are refused by Authelia). New users get a *pending* Open WebUI account that an admin approves. `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=false`: signup emails are unverified, so never link accounts by email |
| Jellyfin | **No gate** (removed 2026-11-08); the login page is public. **Authelia-Auth plugin** (`plugins/authelia`): form and API logins (Finamp, Apple TV) validate against Authelia 1FA — server-side `/api/firstfactor` + `/api/authz/auth-request`; the plugin's Authelia server must be `https://auth.ftoralesacosta.me` (session cookie domain), its Jellyfin URL `https://jellyfin.ftoralesacosta.me/authz` matches the one_factor `^/authz$` rule (admin+family). New users auto-create with unknowable local passwords; `admin` group grants Jellyfin admin; libraries granted manually once. The SSO-Auth plugin + its OIDC client were removed the same day (single form/API door, 1FA — Jellyfin holds media only). Break-glass: `authelia/jellyfin-breakglass.sh` |
| Bindery | **Proxy SSO**: gate snippet forwards `Remote-User`; Bindery auth mode "proxy" (set via API, `PUT /api/v1/auth/mode`). Passing users log straight in; new usernames auto-provision as role `user`. Gate rule: groups `admin` + `family` |
| *arr (prowlarr/lidarr/sonarr/radarr) | **Gate + External auth**: gate snippet on all four hosts; apps run `AuthenticationMethod=External` (config.xml) so the gate login is the only login; Authelia bypasses `/api` + `/[0-9]+/api` for API-key clients; UI rule: `two_factor`, groups `admin` + `family` |
| Seerr | **Gate**: same shape as the *arr rule — `/api` bypassed for API-key clients, UI `two_factor` for groups `admin` + `family` (request manager; its own logins stay for the API only) |
| SABnzbd, qBittorrent | **Gate**, admin only, no `/api` bypass (the *arrs talk to `sabnzbd:8080` / `vpn-gateway:8080` directly) |
| Bazarr | **Gate**, admin + family (own form login stays as a second layer) |
| Others (Kavita, Actual, website) | Own logins. Gate a host with `nginx-proxy-manager/add-host.sh <domain> <fwd> --authelia --update` + an `access_control` rule |

Add an OIDC app: add a client under `identity_providers.oidc.clients` in `configuration.yml` (template in
`configuration.example.yml`; secrets with `authelia crypto rand` / `authelia crypto hash generate pbkdf2`),
then check and restart:
```bash
docker run --rm -e AUTHELIA_NOTIFIER_SMTP_PASSWORD=x -v $PWD/configuration.yml:/config/configuration.yml:ro \
  -v $PWD/users:/config/users:ro ghcr.io/authelia/authelia:4.39 \
  authelia validate-config --config /config/configuration.yml
docker restart authelia
```

Plan and history: [`../homelab-sso-rollout.md`](../homelab-sso-rollout.md).
