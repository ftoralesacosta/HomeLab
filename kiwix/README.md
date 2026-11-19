# Kiwix (offline Wikipedia)

https://wiki.ftoralesacosta.me serves offline copies of Wikipedia (and any other ZIM files)
with `kiwix-serve`. Search works offline: the full-text index is inside each ZIM file.

| Item | Value |
|---|---|
| Container | `kiwix` (`ghcr.io/kiwix/kiwix-serve:3.8.2`), on `proxy-net`, no host port, read-only |
| Files | `/mnt/data/kiwix` on the 2 TB NVMe: `*.zim` + `library.xml`. Not backed up (re-downloadable) |
| Access | NPM host `wiki.` with the Authelia gate; `access_control`: admin, family, friends, password only (`one_factor`) |
| DNS | `wiki.` A record kept by `cloudflare-ddns` (proxied) |
| Updates | `kiwix/update.sh`, monthly from fernando's crontab (2nd, 04:15). Log: `kiwix/logs/cron.log` |

## Why the NVMe

Kiwix does many small random reads (articles, images, the search index). The NVMe answers in
~0.1 ms, the media HDD in ~8-10 ms per seek while Jellyfin streams from it. One ~120 GB write
about twice a year is nothing for the SSD's endurance.

## Content

`BOOKS` at the top of `update.sh` lists what to keep current, as `<listing dir>/<name without date>`
from https://download.kiwix.org/zim/. Currently:

| Book | Size (2026-08) |
|---|---|
| `wikipedia/wikipedia_en_all_maxi` (all articles, with images) | 119 GB |

Add a line (e.g. `wiktionary/wiktionary_en_all_maxi`, `stack_exchange/...`) and run the script.

## How `update.sh` works

1. Find the newest file name for each book in the Kiwix listing; skip it if it is already here.
2. Check free space, then download it into `.incoming/` with `aria2c` from Kiwix's metalink
   (several mirrors in parallel, resumable: rerun the script to continue).
3. Verify the published `.sha256`. On a mismatch the download is deleted and the script stops.
4. Move it next to the others and `kiwix-manage library.xml add` it; then remove the older
   version from the library and delete its file. `--monitorLibrary` reloads without a restart.

```bash
~/HomeLab/kiwix/update.sh --check   # what would be downloaded
~/HomeLab/kiwix/update.sh           # do it (safe to rerun; a lock prevents two runs)
```

## Notes

- Download speed is limited by the server's Wi-Fi link (~110 Mbit/s total); the first download
  took about 3 hours. A torrent through qBittorrent was slower (the same link plus the VPN).
- `/mnt/data` is root-owned; `/mnt/data/kiwix` was created with
  `docker run --rm -v /mnt/data:/m alpine:3 sh -c "mkdir -p /m/kiwix && chown 1000:1000 /m/kiwix"`.
