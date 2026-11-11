# Authelia

Authelia is the login page and the OIDC provider for the homelab: https://auth.ftoralesacosta.me.
The main [README](../README.md#login-and-access-authelia) shows which group can use which app.
This file tells you how to operate it.

- Container `authelia`, image pinned to `4.39`, because `:latest` broke the config once.
- It runs as uid 1000 on `proxy-net`. NPM reaches it at `authelia:9091`. It has no host port.

## Files

| File | In git | Contents |
|---|---|---|
| `configuration.yml` | no | The live config, with secrets (JWT, storage key, OIDC keys) |
| `configuration.example.yml` | yes | The same structure, with placeholders |
| `users/auth_file.yml` | no | Users, password hashes and groups |
| `auth_file.example.yml` | yes | A user template |
| `${DOCKERDIR}/authelia/data` | no | SQLite: sessions, TOTP and security keys (the nightly backup includes it) |

Authelia watches `users/auth_file.yml` and loads changes by itself, so you do not restart it after
user changes. The repo mounts the `users/` directory, not the file, because the file watcher needs
the real directory. Authelia rewrites the file in a longer format when a user changes their
password. That is normal.

Emails (password reset, 2FA setup) go out through Gmail with `GMAIL_APP_PASSWORD` from `../.env`.

## Users

| Task | How |
|---|---|
| Add a user | `./add-user.sh <user> <email> "<Name>" <group>`. Use `--dry-run` first to preview |
| Approve a signup | `./approve-user.sh <user> [family\|friends]` (default `family`) |
| Disable a user | Set `disabled: true` in `users/auth_file.yml` |
| Remove a lost 2FA device | `docker exec authelia authelia storage user totp delete <user> --config /config/configuration.yml`<br>`docker exec authelia authelia storage user webauthn delete <user> --all --config /config/configuration.yml` |

**A user you add** gets a random password. Send them the message that `add-user.sh` prints. They
click **Reset password?** on the login page, choose a password, and log in.

**Self-signups** (https://signup.ftoralesacosta.me) start in the `pending` group, and you get an
email. Signup does not verify the email address, so check the request before you approve it.

**Open WebUI** needs no separate approval. The OIDC login creates the account with role *user*
(`DEFAULT_USER_ROLE=user`): Authelia's `approved` policy already vetted the group, so anyone who can
complete the OIDC login is allowed in.

Groups: `admin`, `family`, `friends`, `pending`. Never give `admin` to friends.

## Two-factor authentication

All gated apps and Open WebUI need a password and a second factor. The login page itself needs
only the password.

- **TOTP**: any authenticator app.
- **Security key or passkey**: as the second factor only. Passkey-only login is off.

To enroll: log in at https://auth.ftoralesacosta.me → **Two-Factor Authentication** → add a TOTP
app or a security key. Users who open a 2FA app without a device go to enrollment automatically.

To add a second device, a user must confirm with the device they already have
(`identity_validation.elevated_session`). This stops somebody with only a stolen password from
adding their own device.

## How the apps connect

| App | Method | Setup details |
|---|---|---|
| Most apps | Gate | NPM host Advanced config: `include /snippets/authelia.conf;`. Then add a rule to `access_control` in `configuration.yml` and restart Authelia |
| Sonarr, Radarr, Lidarr, Prowlarr | Gate | The apps use `AuthenticationMethod=External` (config.xml), so the gate is their only login. `/api` and `/<n>/api` skip the gate |
| Bindery | Gate + user name from the gate | Auth mode `proxy`, set with `PUT /api/v1/auth/mode`. It reads the `Remote-User` header. The first admin's user name must be the same as in Authelia |
| Open WebUI | OIDC client `open-webui` | Authorization policy `approved` (admin, family, friends with 2FA). `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=false`, `DEFAULT_USER_ROLE=user` |
| Jellyfin | Authelia-Auth plugin | The plugin's Authelia URL must be `https://auth.ftoralesacosta.me`. Its Jellyfin URL `https://jellyfin.ftoralesacosta.me/authz` must match the `^/authz$` rule. New users are created automatically, and the `admin` group gets Jellyfin admin. You must give new users library access once |

**Add an OIDC app:**
1. Add a client under `identity_providers.oidc.clients` in `configuration.yml`
   (use `configuration.example.yml` as the template).
2. Make the secret with `authelia crypto rand` and its hash with `authelia crypto hash generate pbkdf2`.
3. Check the config, then restart:
   ```bash
   docker run --rm -e AUTHELIA_NOTIFIER_SMTP_PASSWORD=x \
     -v $PWD/configuration.yml:/config/configuration.yml:ro -v $PWD/users:/config/users:ro \
     ghcr.io/authelia/authelia:4.39 authelia validate-config --config /config/configuration.yml
   docker restart authelia
   ```

## If Authelia is down

- Open WebUI: password login at https://webui.ftoralesacosta.me/auth?form=1.
- Jellyfin: `./jellyfin-breakglass.sh [user]` switches the user back to a local Jellyfin password.
- Look for the cause: `docker logs authelia`. A bad `configuration.yml` stops it at start.
