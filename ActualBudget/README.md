# Actual Budget

Actual Budget is the budgeting app at https://budget.ftoralesacosta.me. Bank transactions come in
through **SimpleFIN**. Every morning a few jobs import, categorize and clean up the transactions.

| Part | What it is |
|---|---|
| `actual` (container `actual-budget`) | The Actual server. Port 5006 is also open on the LAN |
| `actual-ai` | Asks an LLM (CoreWeave) to categorize new transactions |
| [`../actual-ai/scripts/`](../actual-ai/scripts/) | Small scripts that cron runs inside the `actual-ai` container |

All app data is in `${DOCKERDIR}/actual-budget/data`: `server-files/` (accounts, the SimpleFIN key)
and `user-files/` (the budgets). The nightly backup includes it. The only config in git is the
service block in [docker-compose.yml](../docker-compose.yml).

## The daily jobs

| Time | Job | What it does |
|---|---|---|
| 05:45 | `bank-sync.js` (cron) | Syncs each bank account separately. A broken bank connection is logged and skipped, so the other accounts still sync |
| 06:00 | `actual-ai` (its own schedule) | Gives a category to uncategorized transactions and adds `#actual-ai` to their notes, so you can review them. It does not make rules |
| 06:45 | `daily-fixups.js` (cron) | No AI. Links payments between your own accounts (like "Make transfer"), and gives refunds the category of the purchase. Each change goes to `actual-ai/logs/daily-fixups.jsonl`, with the data to undo it |

Why bank sync is not in `actual-ai`: `actual-ai` stops completely when one bank connection fails.

To run a job now: `docker exec actual-ai node /scripts/<script>.js`.
To make `daily-fixups.js` only log and change nothing, set `FIXUPS_DRY_RUN: "true"` in the compose file.
When you add a credit card or account, update the account list at the top of `daily-fixups.js`.

## Settings and reasons

- `ACTUAL_UPLOAD_FILE_SYNC_SIZE_LIMIT_MB=100`: the default 20 MB is too small for a few years of history.
- `ACTUAL_TRUSTED_PROXIES` is not set. Its default already includes the private ranges, so it
  trusts NPM on the Docker network.
- Login is **OpenID through Authelia** (see "Login" below). There is no forward-auth gate
  (`authelia.conf`), so the web app and PWA sync normally. The desktop (Electron) app is not used.
- The public address must use HTTPS. Actual's encryption needs `window.crypto.subtle`, and browsers
  only give that to secure sites. NPM supplies the HTTPS. The LAN port 5006 stays plain HTTP.

## Login (Authelia OpenID)

- Authelia OIDC client `actual-budget`, policy `admin_only` (group `admin`, two-factor).
  Plaintext secret: `ACTUAL_OPENID_CLIENT_SECRET` in `~/HomeLab/.env`; digest in
  `authelia/configuration.yml`. Callback: `https://budget.ftoralesacosta.me/openid/callback`.
- The `ACTUAL_OPENID_*` variables are in the compose file. When the server starts with them, it makes
  OpenID the active login method. `ACTUAL_OPENID_ENFORCE=true` hides the password option in the UI.
- The **first** OpenID login became the server owner, and the budget files moved to that user.
  Other Authelia users cannot log in until the owner adds them in Actual (*Server → User Directory*),
  and they also need the `admin` group in Authelia.
- **The scripts still use the server password** (`ACTUAL_PASSWORD`). `@actual-app/api` can only log in with
  a password, so `ACTUAL_ALLOWED_LOGIN_METHODS=openid,password`. The scripts connect to
  `http://actual-budget:5006` on the Docker network. From the internet, NPM allows only OpenID logins:
  the `budget.` host includes `nginx-proxy-manager/snippets/actual-login-filter.conf`, which returns 403
  for any `POST /account/login` that is not `loginMethod: "openid"`.
- LAN port 5006 skips NPM, so password login still works from the LAN.
- To go back to password-only: remove the `ACTUAL_OPENID_*` and `ACTUAL_ALLOWED_LOGIN_METHODS` lines,
  then in Actual use *Settings → Authentication → Switch to password* (this needs the server password).

## SimpleFIN

1. Get a **setup token** from the SimpleFIN Bridge dashboard.
2. In Actual: **+ Add account** → **Link bank account with SimpleFIN** → paste the token.

Actual changes the token into a long-lived key and keeps it in `server-files/`.

- The setup token works **one time only**. If it fails, or you lose `/data`, get a new token.
  To change the credentials: ⋮ next to SimpleFIN → *Reset SimpleFIN credentials*.
- SimpleFIN updates about **once per day**. A transaction that shows a day late is normal.
- SimpleFIN gives **90 days of history at most**. Import older history from CSV or QFX.

## New machine

1. Restore `${DOCKERDIR}/actual-budget/data` from the backup (see [backup/README.md](../backup/README.md)).
2. `docker compose up -d actual actual-ai`.
3. Add the cron jobs (the list is in the backup README, section B).
4. If you did not restore the data, set a new server password and link SimpleFIN again.

The NPM host `budget.` points to `actual-budget:5006`. DNS is a proxied Cloudflare CNAME
`budget → ftoralesacosta.me`.
