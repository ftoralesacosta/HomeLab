# Homelab SSO Rollout — Authelia, SearXNG, Actual Budget

Date: 2026-10-19
Decisions (2026-10-20, final):
- Architecture: NPM "Authelia" access list is a **gate** (defense-in-depth), not SSO —
  apps with their own logins still show them. True single login via OIDC is the
  follow-up for the gated apps, see Tier A in section 4.
- **Gate scope**: the SSO-ready list (jellyfin, ha, webui, portainer) + the NPM UI
  itself + searxng. The arr stack (radarr, sonarr, prowlarr, sabnzbd, qbittorrent,
  bazarr) is **not** gated — it keeps its own logins with strong unique passwords.
- Exceptions (confirmed OK): public website (apex) and `budget` (would break Actual
  desktop/mobile sync — see section 3).
Status: 2026-10-20 — **Authelia v4.39.28 is running** (clean boot, HTTP 200 on
`127.0.0.1:9091`, `/api/verify` answers 401 to a fake token, so the NPM
Authelia access-list method is compatible — no tag pinning needed at the time; UPDATE 2026-10-24: image now pinned to 4.39 after :latest rejected notifier.smtp.starttls; notifier uses address: submission://smtp.gmail.com:587 and session uses the cookies: list). Config is
written for the v4.38+ schema (the v5-style keys are rejected by this image);
the user file uses the 4.38+ map format (`users` keyed by username).
SearXNG is up with LAN ports on `192.168.4.51:8888` and `192.168.1.100:8888`.
Status: local setup complete on disk; containers pending `docker compose up -d authelia searxng`
(the automated approval service for the agent's docker access was down when this was written).

---

## What was set up (on disk, ready to start)

- `~/HomeLab/authelia/configuration.yml` — Authelia config: SQLite storage, file-based
  identity provider, session cookie scoped to `ftoralesacosta.me` (one login covers all
  subdomains). Secrets are gitignored; tracked templates and the
  user-management guide live in `~/HomeLab/authelia/README.md`.
- `~/HomeLab/authelia/auth_file.yml` — first user `fernando` in groups `admin` + `family`,
  plus a commented template for adding family members.
- `~/HomeLab/docker-compose.yml` — new `authelia` service on `proxy-net` (NPM reaches it at
  `authelia:9091`) with a loopback test port `127.0.0.1:9091`, and a **LAN-only** port for
  searxng LAN ports `192.168.4.51:8888:8080` and `192.168.1.100:8888:8080`
  (both NICs; the loopback port used by the Hermes agent is untouched).
- `.gitignore` now excludes the two secret files.

Changes not yet committed to git: `.gitignore`, `docker-compose.yml`, new `authelia/` directory.

## 1 — Authelia: required nginx/NPM changes (final step)

1. Cloudflare: CNAME `auth → ftoralesacosta.me` (proxied, like the other records).
2. NPM → Proxy Host: `auth.ftoralesacosta.me` → forward to `authelia:9091`
   (http, SSL automation, force SSL) — same pattern as the other hosts.
3. NPM → Access Lists: add one named `authelia`, authentication method **Authelia**,
   server URL `https://auth.ftoralesacosta.me`.
4. Assign that access list to the hosts listed in section 5:
   jellyfin, ha, webui, portainer, nginx (the NPM UI), and `search` (searxng)
   once it exists.

No hand-written nginx config is needed anywhere; NPM handles the whole integration.

## 2 — SearXNG web UI (cautious path)

**Now, LAN testing:** after the recreate, open `http://192.168.4.51:8888` from a LAN device (or `http://192.168.1.100:8888` on the second network).
It is *not* internet-reachable — there is no NPM host and no DNS record for it, so there is no
public attack surface until exposure is explicitly added.

**Public exposure (final step, in this order):**

1. Enable `server.limiter: true` in `~/HomeLab/searxng/settings.yml` (bot rate-limiting;
   currently off).
2. Cloudflare CNAME `search → ftoralesacosta.me`.
3. NPM host `search → searxng:8080` with the **Authelia access list**.
4. Optional extra: NPM access lists also accept IP restrictions, combinable with the Authelia
   auth (e.g. a home-IP or VPN-range whitelist).

Why this is abuse-safe:

- unauthenticated visitors only ever see the login page;
- `public_instance` stays `false`;
- the limiter caps request rates;
- the JSON API used by the host agent is behind auth once public, and the local agent keeps
  using the loopback port (unaffected).

## 3 — Actual Budget / SimpleFIN: current state

- Container is up and the data dir is initialized (Oct 7), but **no server password is stored**
  in the DB — the first-visit setup wizard is likely still pending. Open
  `http://192.168.4.51:5006` on the LAN and set a long random server password (it is the only
  credential guarding the whole budget).
- **SimpleFIN needs zero nginx/Cloudflare changes** — it is an in-app integration:
  SimpleFIN Bridge → copy a setup token → Actual sidebar → *+ Add account* →
  *Link bank account with SimpleFIN* → paste. One-time; the token is single-use.
- Final step: Cloudflare CNAME `budget → ftoralesacosta.me` + NPM host
  `budget → actual-budget:5006` (already documented in `ActualBudget/README.md`),
  **without** the Authelia access list.
- **Why `budget` is the only gated-everywhere exception:** Actual's desktop/mobile clients
  sync straight to the API with only the server password and cannot present an Authelia
  token. The gate would not cause a double login — it would hard-break remote sync.
  Protection = strong server password + TLS. (If you ever want remote access restricted
  further, NPM IP restrictions work without breaking the API, unlike the auth gate.)
- Optional later: Actual's web UI can join Tier A (OIDC SSO) — its DB already contains the
  `pending_openid_requests` table, so OIDC login is built into the running version. OIDC only
  covers the browser login; sync clients keep using the server password.

## 4 — Single login across services

**Key distinction (why the arrs are NOT single-login):**

- The NPM "Authelia" access list is a **gate**, not SSO. It blocks unauthenticated traffic at
  the proxy, but the app behind it still shows **its own** login screen. Gating Radarr means:
  Authelia login (once per browser session, then automatic), then Radarr login.
  Accepted per the gate-everything decision.
- True "one login replaces the app login" is **OIDC SSO**: Authelia acts as the identity
  provider, each app authenticates against it, and each app silently creates/maps a local
  account on first login. Optional layer on top of the gate — the gate does not prevent it.

**Tier A — OIDC SSO candidates (optional, do after the gate is live):**

| App | OIDC support |
| --- | --- |
| Jellyfin | yes, since 10.9 (running `latest`) |
| Open WebUI | yes, built-in |
| Portainer CE | yes, built-in (Settings → Authentication) |
| Actual (web UI) | yes (evidence: `pending_openid_requests` table in its DB) |
| Home Assistant | believed supported in recent core (`auth: - type: oidc`); **verify against the running version before wiring** |

With the gate in place, steady state for Tier A apps can become zero-typing: the gate
auto-passes with the existing token, and the in-app OIDC login auto-approves with the
existing Authelia session.

Authelia side needs no client registration — each app just gets: issuer
`https://auth.ftoralesacosta.me`, a client ID/secret defined in the app, scopes
`openid profile email`. Discovery endpoint:
`https://auth.ftoralesacosta.me/.well-known/openid-configuration`.

Multi-user payoff: adding a family member is one entry in `auth_file.yml`; they log into
Authelia once and get through every gate (and, if done, every Tier A app provisions their
account on first use). Enabling TOTP on the Authelia account flows through to all of them.

**Jellyfin split path:**

- Gate `jellyfin.ftoralesacosta.me` with the Authelia access list for browser access.
- Keep native TV/phone clients on the dedicated internal-only proxy at `192.168.4.51:8443`
  (`jellyfin-internal-proxy` → `jellyfin:8096`).
- This avoids exposing an auth bypass on the public hostname while still supporting clients
  that cannot perform a browser login.

**Not gated (decided):**

- `ftoralesacosta.me` (apex) — public portfolio site.
- `budget` — see section 3 (API clients can't present a token).
- The arr stack (radarr, sonarr, prowlarr, sabnzbd, qbittorrent, bazarr) — no SSO
  support in any of them, so the gate would only add a double login; they keep
  their own logins. Mitigation: strong unique password per app (password manager).
  Revisit if any of them gain OIDC support someday.

## 5 — Final-step checklist (NPM + Cloudflare, do after LAN testing)

Stock NPM Access Lists only provide Basic Auth and IP rules, not a native Authelia
method/server field. Use the reusable include in
`nginx-proxy-manager/snippets/authelia.conf` instead.

1. Cloudflare: CNAMEs (proxied) — `auth`, `search`, `budget` → `ftoralesacosta.me`.
2. NPM → Proxy Host: add `auth.ftoralesacosta.me` → `authelia:9091` (SSL automation,
   force SSL) — do this first, the other hosts depend on it working.
3. NPM → Proxy Host: add `search.ftoralesacosta.me` → `searxng:8080` (SSL automation,
   force SSL) — with `server.limiter: true` already enabled in settings.yml.
4. NPM → Proxy Host: add `budget.ftoralesacosta.me` → `actual-budget:5006` (SSL
   automation, force SSL) — no Authelia gate.
5. For each gated host, open the host’s **Advanced** tab and add:
   `include /snippets/authelia.conf;`
   - `nginx.ftoralesacosta.me`
   - `ha.ftoralesacosta.me`
   - `webui.ftoralesacosta.me`
   - `jellyfin.ftoralesacosta.me`
6. Do **not** add the include to `auth.ftoralesacosta.me`, `budget`, the public site,
   or the arr stack.
7. Smoke test each gated host: expect a bounce to `auth.ftoralesacosta.me`, then the app.

## 6 — Immediate next steps

```bash
cd ~/HomeLab && docker compose up -d authelia searxng
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9091/   # expect 200
docker logs --tail 20 authelia
```

- Password for `fernando` was set directly in `auth_file.yml` on 2026-10-21
  (delivered out-of-band; in the password manager). Not stored in this doc.
- Heads-up: the NPM `ha` host still forwards to `192.168.4.32`, but the host's
  current LAN IP is `192.168.4.51` — if `ha.ftoralesacosta.me` stopped working,
  update that host's Forward Host (or give the machine a static IP).
- Open `http://192.168.4.51:5006` to finish Actual's first-visit setup (server password),
  and `http://192.168.4.51:8888` to check the SearXNG UI on the LAN.

## Update 2026-10-24 — Open WebUI on OIDC SSO (Tier A, first app)

- Authelia `identity_providers.oidc` enabled (key + HMAC secret + client digest only in the
  gitignored `authelia/configuration.yml`; placeholders in `configuration.example.yml`).
  Discovery: `https://auth.ftoralesacosta.me/.well-known/openid-configuration`.
- Client `open-webui`: policy `one_factor`, redirect `https://webui.ftoralesacosta.me/oauth/oidc/callback`.
- Open WebUI (`/opt/open-webui/docker-compose.yml`, root-owned, not in this repo): OAuth env vars
  added; plaintext client secret in `/opt/open-webui/.env` (`OAUTH_CLIENT_SECRET`).
  `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` links the existing `ftoralesacosta@gmail.com` account;
  `ENABLE_OAUTH_SIGNUP=false` (no new accounts via SSO). Password login form still enabled.
  Backups: `*.bak-20261024-preoidc` next to each edited file.
- Next: once the SSO login is confirmed, optionally set `ENABLE_LOGIN_FORM=false` in Open WebUI;
  consider `two_factor` (TOTP) for the client.

## 7 — Current action checklist

Already done in the repo:

1. Added the internal-only Jellyfin listener at `192.168.4.51:8443`.
2. Removed Jellyfin’s broad `8096:8096` host-port exposure.
3. Added a dedicated `jellyfin-internal-proxy` container for the Apple TV path.

Do these next, in order:

1. Run `cd ~/HomeLab && docker compose up -d reverse-proxy jellyfin`.
2. In NPM, open `nginx.ftoralesacosta.me` → **Advanced** and add `include /snippets/authelia.conf;`
3. Confirm the NPM UI still works, then repeat for `ha.ftoralesacosta.me`.
4. Add the same include to `jellyfin.ftoralesacosta.me` last.
6. On Apple TV, use `http://192.168.4.51:8443` and sign in with the normal Jellyfin account.
7. Optional hardening: once the gated NPM host works, restrict or remove the direct `81:81` port mapping.
