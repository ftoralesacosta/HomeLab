# Nginx Proxy Manager

NPM is the reverse proxy on ports 80 and 443. It gives each `*.ftoralesacosta.me` subdomain a
TLS certificate and sends it to a container.

- Admin UI: http://192.168.4.51:81 (LAN only). When you are away:
  `ssh -L 8181:localhost:81 fernando@ftoralesacosta.me`, then open http://localhost:8181.
- Proxy hosts are in NPM's database (`${DOCKERDIR}/nginx-proxy-manager/data`), not in this repo.
- [`snippets/authelia.conf`](snippets/authelia.conf) is the Authelia gate. NPM mounts it read-only at `/snippets`.

## add-host.sh

`add-host.sh` creates, changes, lists and deletes proxy hosts. It uses the same API as the UI.
It reads `NPM_ADMIN_EMAIL` from `../.env` and asks for the password. It does not store the password.

```bash
./add-host.sh --list                                              # all hosts: target, SSL, gate
./add-host.sh kavita.ftoralesacosta.me kavita:5000                # new host
./add-host.sh bindery.ftoralesacosta.me bindery:8787 --authelia   # new host behind the gate
./add-host.sh kavita.ftoralesacosta.me kavita:5000 --update       # change a host (keeps its certificate)
./add-host.sh test.ftoralesacosta.me test:80 --dry-run            # show what it would send
./add-host.sh --delete test.ftoralesacosta.me                     # asks first; -y skips the question
```

Run `./add-host.sh --help` for all options.

- **Defaults:** Force SSL, WebSockets, HTTP/2 and "Block Common Exploits" are on.
- **Certificates:** the script uses an existing certificate that covers the name. All hosts share
  the wildcard `*.ftoralesacosta.me` (certificate 7), so you do not need a certificate flag.
  The script cannot make wildcard certificates (they need a DNS challenge). Use the UI for them.
- **`--update`:** the flags you give replace the host's settings. Give the flags again for
  settings that are not default (for example `--no-http2`).
- **Target:** use the container name (`kavita:5000`), not the host IP. NPM is on `proxy-net` with the apps.

## The gate (`--authelia`)

`--authelia` adds one line to the host's Advanced config: `include /snippets/authelia.conf;`.
Visitors then go to the Authelia login. To decide who gets through, add a rule to
`access_control` in `../authelia/configuration.yml` and restart Authelia. Until a rule exists,
Authelia refuses everyone.

The gate also sends the user name to the app in the `Remote-User` header. Apps that trust this
header (Bindery) must never have a host without the gate, because then a visitor could send any name.

## Problems

| Message or symptom | Cause |
|---|---|
| `NPM login failed (HTTP 401)` | Wrong `NPM_ADMIN_EMAIL` in `../.env`, or wrong password |
| `create failed (HTTP 400)` | The name already exists, or the target is not valid |
| The site shows 502 | Wrong container name or port, or the container is not on `proxy-net` |
| A new certificate does not come | Let's Encrypt uses HTTP-01: DNS must point here and the Cloudflare proxy must be off for that name. Log: `docker exec nginx-proxy-manager tail -n 30 /data/logs/letsencrypt.log` |
