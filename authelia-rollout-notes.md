# Homelab Authelia rollout — session notes

Last updated: 2026-10-28  
Status: **Done (fixed 2026-10-28 00:18).** See section 16 for the final fix; sections 10-14 describe the broken intermediate state.

This file is a full record of the Authelia/NPM/Jellyfin work done in this session, including the current state, decisions, exact file changes, database edits, failures, and remaining next steps.

---

## 1. High-level goal

- Put selected public services behind an Authelia **gate** at Nginx Proxy Manager.
- Keep Authelia as a **gate**, not a replacement for the apps’ own login screens.
- Add true SSO only where the app supports it.
- Give Jellyfin a secure, internal-only path for Apple TV and other native clients that cannot perform a browser login.
- Keep the reverse proxy independent from Jellyfin and from Authelia’s availability.

---

## 2. Decisions made

| Topic | Decision |
|---|---|
| Authelia model | Use NPM as a **gate** in front of selected apps. Apps still show their own login screens unless they also support OIDC. |
| NPM UI | Gate `nginx.ftoralesacosta.me` behind Authelia. |
| Home Assistant | Gate `ha.ftoralesacosta.me` behind Authelia, but verify companion app and webhook behavior afterward. |
| Jellyfin | Gate `jellyfin.ftoralesacosta.me` behind Authelia for browser access. |
| Apple TV / native Jellyfin clients | Use a dedicated internal-only proxy at `http://192.168.4.51:8443`. |
| Portainer | Removed from the gate plan because it is not being used. |
| Actual Budget | Not gated; API clients cannot present the Authelia session. |
| Arr stack | Not gated; no real SSO support, so the gate would only add a double login. |
| Public portfolio | Not gated. |
| NPM Access Lists | Do **not** use them for Authelia. Stock NPM Access Lists only support Basic Auth and IP rules. |
| Authelia integration method | Use a reusable Nginx include in each host’s **Advanced** config. |
| Internal Jellyfin proxy | Use a separate `jellyfin-internal-proxy` container, not NPM. |
| Reverse-proxy dependency | Do **not** make NPM depend on Jellyfin. |

---

## 3. Current service map

| Service | Public host | Gate status | Notes |
|---|---|---|---|
| Authelia | `auth.ftoralesacosta.me` | Not gated | Must remain ungated. |
| NPM UI | `nginx.ftoralesacosta.me` | **Database updated to include Authelia gate** | Needs the read-only mount fixed before it will work. |
| Home Assistant | `ha.ftoralesacosta.me` | **Database updated to include Authelia gate** | Needs the same NPM fix. Test mobile app and webhooks afterward. |
| Jellyfin | `jellyfin.ftoralesacosta.me` | **Database updated to include Authelia gate** | Needs the same NPM fix. |
| Open WebUI | `webui.ftoralesacosta.me` | Already using Authelia OIDC | OIDC client already configured. |
| Actual Budget | `budget.ftoralesacosta.me` | Not gated | Intentional. |
| Arr stack | various | Not gated | Intentional. |
| Public portfolio | `ftoralesacosta.me` | Not gated | Intentional. |

---

## 4. Files changed in the repo

### `HomeLab/docker-compose.yml`

Relevant current sections:

- NPM service starts at `HomeLab/docker-compose.yml:7`.
- NPM currently mounts `authelia.conf` read-only at `HomeLab/docker-compose.yml:18`.
- Dedicated internal Jellyfin proxy service starts at `HomeLab/docker-compose.yml:109`.
- Jellyfin service starts at `HomeLab/docker-compose.yml:120`.
- Jellyfin’s old `8096:8096` host port was removed.
- The internal proxy publishes only `192.168.4.51:8443`.

### `HomeLab/nginx-proxy-manager/snippets/authelia.conf`

This is the reusable Authelia gate include used by NPM hosts:

- Resolves the Authelia container through Docker DNS.
- Excludes Let’s Encrypt ACME challenges.
- Uses `auth_request` to call Authelia’s `/api/verify`.
- Redirects unauthenticated users to `https://auth.ftoralesacosta.me`.

### `HomeLab/jellyfin-internal-proxy/nginx.conf`

This is the internal-only Jellyfin proxy:

- Listens on port `8443`.
- Proxies to `jellyfin:8096`.
- Uses Docker DNS so it does not need a static Jellyfin container IP.
- Forwards WebSocket headers for Jellyfin clients.

### `HomeLab/README.md`

Updated to describe the Jellyfin split path:

- Public browser access through Authelia.
- Native TV/phone clients through `jellyfin-internal-proxy`.

### `HomeLab/homelab-sso-rollout.md`

Updated to:

- Document that stock NPM Access Lists do not support Authelia natively.
- Replace the old Access List instructions with the per-host **Advanced** include.
- Document the dedicated `jellyfin-internal-proxy` approach.
- Add a current action checklist.

---

## 5. Security model

### What “gate” means

A **gate** means NPM asks Authelia whether the request is authenticated **before** forwarding the request to the app.

- If Authelia says no, NPM redirects the browser to the Authelia login page.
- If Authelia says yes, NPM forwards the request to the app.
- The app may still show its own login screen.

A gate is **not** the same as SSO.

### What “SSO” means

SSO means the app itself trusts Authelia as an identity provider, usually through OIDC.

- Open WebUI is already using this model.
- Jellyfin is not yet using this model.
- Home Assistant is not yet using this model.

---

## 6. Apple TV / Jellyfin path

The chosen approach is a **dedicated internal-only reverse proxy**.

### Why this was chosen

| Option | Assessment |
|---|---|
| Dedicated internal-only proxy | Chosen. Best security and isolation. |
| Direct Jellyfin port on the host | Rejected. Broader exposure and less control. |
| IP bypass on the public Jellyfin host | Rejected. Would create an auth bypass on a public hostname. |
| Making NPM depend on Jellyfin | Rejected. Unnecessary coupling. |

### Current internal path

```text
Apple TV / native client
        |
        v
http://192.168.4.51:8443
        |
        v
jellyfin-internal-proxy
        |
        v
jellyfin:8096
```

### Jellyfin client behavior

- Use `http://192.168.4.51:8443`.
- Sign in with the normal Jellyfin account.
- Quick Connect is optional if the app supports it.

---

## 7. NPM Access List discovery

### What was found

NPM’s Access List UI has these tabs:

- `Details`
- `Authorization`
- `Access`

There is **no native Authelia method or server field**.

### Why

Stock NPM Access Lists support:

- Basic Auth
- IP allow/deny rules

They do **not** natively support Authelia as an auth provider.

### What was done instead

A reusable Nginx include was created:

```text
HomeLab/nginx-proxy-manager/snippets/authelia.conf
```

Each gated host gets this line in its **Advanced** config:

```nginx
include /snippets/authelia.conf;
```

---

## 8. Live NPM database changes

The live NPM database is:

```text
/home/fernando/.volumes/nginx-proxy-manager/data/database.sqlite
```

The relevant proxy host IDs are:

| ID | Host |
|---|---|
| `1` | `jellyfin.ftoralesacosta.me` |
| `7` | `nginx.ftoralesacosta.me` |
| `12` | `ha.ftoralesacosta.me` |
| `15` | `auth.ftoralesacosta.me` |

The `advanced_config` field was updated for IDs `1`, `7`, and `12` to:

```nginx
include /snippets/authelia.conf;
```

The Authelia host (`15`) was **not** modified.

A database backup was created inside the NPM container at:

```text
/data/database.sqlite.bak-authelia-20261028
```

Because `/data` is bind-mounted, this is also accessible from the host at:

```text
/home/fernando/.volumes/nginx-proxy-manager/data/database.sqlite.bak-authelia-20261028
```

---

## 9. How the database update was performed

A direct host-level write to `database.sqlite` failed because the file is owned by `nobody:nogroup` and is not writable by the current user.

Instead, the update was performed **inside the NPM container** as root, using the container’s Python and SQLite module.

This allowed the live database to be updated without changing host file ownership.

---

## 10. Current unresolved issue

### Problem

NPM is currently unhealthy because `authelia.conf` is mounted read-only:

```yaml
- ./nginx-proxy-manager/snippets/authelia.conf:/data/nginx/custom/authelia.conf:ro
```

NPM’s startup script attempts to modify files under `/data/nginx/custom`, including `authelia.conf`.

The container logs show:

```text
/etc/s6-overlay/s6-rc.d/prepare/50-ipv6.sh: line 28:
/data/nginx/custom/authelia.conf: Read-only file system
```

This causes NPM’s startup preparation to fail.

### Why this happened

The custom Authelia include was mounted as a single read-only file.

NPM expects its startup scripts to be able to rewrite or normalize files under `/data/nginx/custom`.

### Required fix

Change the mount from read-only to writable:

```diff
- ./nginx-proxy-manager/snippets/authelia.conf:/data/nginx/custom/authelia.conf:ro
+ ./nginx-proxy-manager/snippets/authelia.conf:/data/nginx/custom/authelia.conf
```

Then recreate NPM:

```bash
cd ~/HomeLab
docker compose up -d --force-recreate reverse-proxy
```

A command to apply this fix was started but was interrupted by the user.

Therefore, the current compose file still contains the `:ro` mount.

---

## 11. Issues encountered and resolutions

| Issue | Cause | Resolution |
|---|---|---|
| NPM blank white page | NPM was not running correctly. | Root cause traced to the custom Authelia mount issue. |
| NPM “web server is down” | NPM was not accepting connections. | Same mount issue. |
| Direct SQLite update failed | Host file was owned by `nobody:nogroup`. | Updated the database from inside the NPM container as root. |
| Access List UI did not have Authelia method | Stock NPM Access Lists do not support Authelia. | Switched to a custom Nginx include per host. |
| NPM was briefly coupled to Jellyfin | I added `depends_on` to the reverse proxy. | Removed it and moved the internal listener to a separate proxy container. |
| NPM was still failing after the dedicated proxy | `authelia.conf` was mounted read-only. | Fix is documented above but not yet applied. |
| Host port `8096` was broadly exposed | Docker published Jellyfin on all host interfaces. | Removed the `8096:8096` mapping. |

---

## 12. Verification already performed

- `docker compose config --quiet` passed.
- NPM’s live database rows for Jellyfin, NPM, and Home Assistant were updated.
- NPM’s Authelia host row remained unchanged.
- A database backup was created.
- NPM was restarted, but its startup prepare service failed because of the read-only custom file mount.

---

## 13. Remaining next steps

1. Remove `:ro` from the `authelia.conf` mount in `docker-compose.yml`.
2. Recreate NPM:
   ```bash
   cd ~/HomeLab
   docker compose up -d --force-recreate reverse-proxy
   ```
3. Confirm NPM is reachable:
   ```text
   http://192.168.4.51:81
   ```
4. Confirm the generated NPM configs include:
   ```text
   include /snippets/authelia.conf;
   ```
5. Test `nginx.ftoralesacosta.me`.
6. Test `ha.ftoralesacosta.me`.
7. Test `jellyfin.ftoralesacosta.me`.
8. Test the internal-only Jellyfin path:
   ```text
   http://192.168.4.51:8443
   ```
9. Verify Apple TV can sign in.
10. After everything works, consider removing or restricting NPM’s direct `81:81` port.

---

## 14. Recovery notes

If NPM remains broken after removing `:ro` and recreating it:

```bash
cd ~/HomeLab
docker compose logs --tail 100 reverse-proxy
```

If the database needs to be rolled back, restore the backup:

```bash
cd ~/HomeLab
docker compose stop reverse-proxy
cp /home/fernando/.volumes/nginx-proxy-manager/data/database.sqlite.bak-authelia-20261028 \
   /home/fernando/.volumes/nginx-proxy-manager/data/database.sqlite
docker compose up -d reverse-proxy
```

---

## 15. Summary

- Authelia is the identity provider and gate.
- Open WebUI already uses Authelia OIDC.
- NPM, Home Assistant, and Jellyfin have been updated in the NPM database to include the Authelia gate.
- The actual Authelia Nginx include is present in the repo.
- Jellyfin now has a dedicated internal-only proxy for Apple TV.
- NPM currently fails because `authelia.conf` is mounted read-only.
- The remaining fix is to remove `:ro` from that mount and recreate NPM.


---

## 16. Resolution (2026-10-28)

What was broken: NPM's start-up script edits every file under `/data/nginx/custom`; the read-only
`authelia.conf` mounted there made it fail, so NPM served nothing (all sites: Cloudflare 521).
Also: the 3 host configs never contained the include (only the DB had it), an abandoned
`custom/stream.conf` (listener on 8443 inside NPM) was left in NPM's data, and Authelia's
`access_control` (default `deny`) had no rules for the gated hosts, so even logged-in users would get 403.

Fix:
- Snippet moved to `nginx-proxy-manager/snippets/authelia.conf`, mounted read-only at `/snippets`
  (outside `/data`, NPM never touches it). Hosts 1, 7, 12 use `include /snippets/authelia.conf;`
  (DB `advanced_config` + regenerated `/data/nginx/proxy_host/{1,7,12}.conf`). The snippet now also
  passes websocket headers (needed by Home Assistant and Jellyfin).
- Removed `/data/nginx/custom/{authelia,stream}.conf` from NPM's data; repo `nginx-proxy-manager/custom/` removed.
- Authelia `access_control`: `nginx.` + `ha.` = group `admin`; `ha.` `/api/` + `/auth/token` = bypass
  (companion app, webhooks); `jellyfin.` = any user; everything else still deny.
- Portainer removed: compose service, container, NPM host 5 (soft-deleted; conf moved to
  `/data/nginx/deleted_hosts/`). Its data dir `${DOCKERDIR}/portainer/data` was left in place.
- Backups: NPM DB `/data/database.sqlite.bak-20261028-fix` (inside the container),
  `authelia/configuration.yml.bak-20261028-fix`.

Verified (external, 00:18): portfolio, webui, auth, arr hosts OK; `jellyfin.`/`nginx.`/`ha.` redirect to
Authelia; `ha.../api/` reaches HA (401 = HA's own auth); internal Jellyfin `http://192.168.4.51:8443` OK;
NPM admin `:81` OK; `nginx -t` OK, no start-up errors.

Still to do by hand: Cloudflare DNS record `portainer` can be deleted (now Cloudflare 525);
Apple TV Swiftfin server address → `http://192.168.4.51:8443`.

### Update 2026-10-28 09:00 — NPM admin UI no longer public
NPM has no SSO, so behind the gate it meant two logins. Decision: no public host at all.
NPM host 7 (`nginx.ftoralesacosta.me`) soft-deleted (conf in `/data/nginx/deleted_hosts/`, DB backup
`/data/database.sqlite.bak-20261028-nonginx`); Authelia admin rule now covers `ha.` only.
Access: home `http://192.168.4.51:81`; away `ssh -L 8181:localhost:81 fernando@ftoralesacosta.me` → `http://localhost:8181`.
Cloudflare DNS record `nginx` can be deleted.
