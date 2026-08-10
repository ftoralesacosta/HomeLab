# Actual Budget

Self-hosted budgeting app (`actualbudget/actual-server`), exposed externally at
`budget.ftoralesacosta.me` through nginx-proxy-manager like Home Assistant and
Jellyfin. Primary use case here is **SimpleFIN bank sync**.

Unlike Home Assistant, there is nothing hand-editable to track in git — Actual
keeps everything (server DB, budget files, bank-sync credentials) inside its
`/data` volume. This README is the setup/bootstrap record; the only tracked
config is the service block in `../docker-compose.yml`.

## What's in the compose file

```yaml
actual:
  image: actualbudget/actual-server:latest
  container_name: actual-budget
  networks: [proxy-net]
  ports: ["5006:5006"]
  volumes:
    - ${DOCKERDIR}/actual-budget/data:/data
```

- **`proxy-net`** is what lets nginx-proxy-manager reach it by container name.
- **`5006:5006`** is published so the app also works over plain LAN
  (`http://<host-ip>:5006`) without going out to the internet and back.
- **`/data`** contains `server-files/` (accounts DB + the SimpleFIN access key)
  and `user-files/` (the actual budget files). Back this up — it's the whole
  application state.
- **`ACTUAL_UPLOAD_FILE_SYNC_SIZE_LIMIT_MB=100`** raises the 20MB default, which
  a budget with a few years of transactions can exceed on sync/import.
- The container runs as root and creates `/data` itself, so no PUID/PGID or
  pre-chowned directory is needed (unlike the linuxserver.io images).

`ACTUAL_TRUSTED_PROXIES` is deliberately unset: it already defaults to the
private ranges (`10/8`, `172.16/12`, `192.168/16`, `fc00::/7`, `::1/128`), which
covers the Docker bridge that nginx-proxy-manager forwards from.

## Bring it up

```bash
cd ~/HomeLab
docker compose up -d actual
docker logs -f actual-budget      # expect: "Listening on :::5006..."
```

Then load `http://<host-ip>:5006` on the LAN and set the **server password**
(this is the only credential guarding the whole budget, and the app is about to
be internet-facing — make it a long random one from the password manager).

## External access

Two pieces, matching how the other public services are wired:

**1. DNS.** The `cloudflare-ddns` containers only maintain the apex record and
`mc`. Add a proxied `CNAME budget → ftoralesacosta.me` in the Cloudflare
dashboard (same as the existing service subdomains) so it follows the apex as
the home IP changes.

**2. nginx-proxy-manager** (`http://<host-ip>:81`) → Hosts → Proxy Hosts → Add:

| Field | Value |
| --- | --- |
| Domain Names | `budget.ftoralesacosta.me` |
| Scheme / Forward Host / Port | `http` / `actual-budget` / `5006` |
| Websockets Support | on |
| Block Common Exploits | on |
| SSL tab | request a new Let's Encrypt cert, Force SSL + HTTP/2 on |

Forwarding to the **container name** works because both containers sit on
`proxy-net`; don't point it at the host IP.

HTTPS is not optional in practice — Actual's end-to-end encryption relies on
`window.crypto.subtle`, which browsers only expose on secure origins, so the
public hostname must be TLS-terminated (it is, by NPM) even though the LAN
`:5006` entrance stays plain HTTP.

## SimpleFIN

All server-side; no environment variables or compose changes involved. Once the
budget file exists:

1. Get a **setup token** from the SimpleFIN Bridge dashboard.
2. In Actual: sidebar → **+ Add account** → **Link bank account with SimpleFIN**
   → paste the token.

Actual exchanges the token for a long-lived access key and stores it in
`/data/server-files`, so this is a one-time step per server.

Gotchas worth remembering:

- **The setup token is single-use.** Exchanging it consumes it; if the paste
  fails or you rebuild `/data` without a backup, generate a fresh one from
  SimpleFIN Bridge. To swap credentials later: the ⋮ menu next to the SimpleFIN
  option → *Reset SimpleFIN credentials*.
- **Data is ~daily, not live.** SimpleFIN refreshes each account roughly once a
  day (timing set by the upstream provider, MX), so a transaction showing up
  late is normal, not a broken sync.
- **At most 90 days of history** is pulled per linked account, and often less
  depending on what the bank exposes. Anything older has to be imported from
  CSV/QFX at setup time.
- Syncing is manual/on-demand from the UI — there's no server-side cron pulling
  transactions in the background.

## Backups

`${DOCKERDIR}/actual-budget/data` (= `/home/fernando/.volumes/actual-budget/data`)
is the only thing that matters. Losing it means losing the budget files *and*
the SimpleFIN access key (recoverable, but needs a new setup token). Actual also
has Settings → Export for a portable per-budget zip.

## Bootstrapping on a new machine

```bash
cd ~/HomeLab
docker compose up -d actual          # creates the /data dir on first run
# restore ${DOCKERDIR}/actual-budget/data from backup, or start fresh and
# re-link SimpleFIN with a new setup token
```

Then redo the Cloudflare CNAME + NPM proxy host above.
