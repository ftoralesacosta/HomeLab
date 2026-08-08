# Home Assistant config (git-backed via symlinks)

The `homeassistant` container's real config lives at
`/home/fernando/.volumes/home-assistant/config` (bind-mounted to `/config`
in the container). That directory also holds the recorder DB, logs,
`.storage/` (entity/device registries), `deps/`, `tts/` cache, and
`custom_components/` — all runtime state that's either huge, regenerated
automatically, or instance-specific junk that doesn't belong in git.

The four files that are actually hand-edited config live here instead,
and `.volumes/home-assistant/config/` has symlinks pointing back at them:

```
.volumes/home-assistant/config/configuration.yaml -> ~/HomeLab/HomeAssistant/configuration.yaml
.volumes/home-assistant/config/automations.yaml    -> ~/HomeLab/HomeAssistant/automations.yaml
.volumes/home-assistant/config/scripts.yaml        -> ~/HomeLab/HomeAssistant/scripts.yaml
.volumes/home-assistant/config/scenes.yaml         -> ~/HomeLab/HomeAssistant/scenes.yaml
```

Home Assistant (including the UI automation editor) reads and writes
through these symlinks completely transparently — it doesn't know they're
links, since `/config` still contains a `automations.yaml` as far as it's
concerned.

## Why the container needs an extra volume mount

Docker only bind-mounts `.volumes/home-assistant/config` into the
container. A symlink inside that directory pointing to
`/home/fernando/HomeLab/HomeAssistant/...` is an absolute host path
*outside* the mounted tree — from inside the container's filesystem
namespace, that path doesn't exist, so the symlink would be dangling.

The fix, already in `../docker-compose.yml`, is a second bind mount at
the identical absolute path:

```yaml
homeassistant:
  volumes:
    - ${DOCKERDIR}/home-assistant/config:/config
    - /home/fernando/HomeLab/HomeAssistant:/home/fernando/HomeLab/HomeAssistant
```

That makes the symlink targets resolve inside the container too.

## What's deliberately NOT tracked here

- **`secrets.yaml`** — stays only in `.volumes/home-assistant/config/`,
  never symlinked or committed. It's currently just HA's default template
  (a placeholder `some_password` key, unused by any `!secret` reference
  in `configuration.yaml`/`automations.yaml`). If you ever add real
  secrets to it, recreate it by hand on any new machine — don't put real
  values in git.
- **`blueprints/`** — only contains HA's own bundled defaults, which HA
  regenerates automatically on startup. Nothing user-authored to back up.
- **`custom_components/`, `.storage/`, `*.db*`, `*.log*`, `deps/`,
  `tts/`** — runtime state / HACS-managed, large, or auto-regenerated.

## Bootstrapping on a brand new machine

```bash
# 1. Clone the repo
git clone git@github.com:ftoralesacosta/HomeLab.git ~/HomeLab

# 2. Set up secrets/env for the whole compose stack
cp ~/HomeLab/.env.example ~/HomeLab/.env
# edit ~/HomeLab/.env and fill in real values (Cloudflare API key,
# Wireguard key, DOCKERDIR=/home/fernando/.volumes, etc.)

# 3. Create the HA runtime config dir (this is where the DB, logs,
#    custom_components, etc. will live — NOT in git)
mkdir -p /home/fernando/.volumes/home-assistant/config

# 4. Recreate secrets.yaml (not backed up — see above). Minimal default:
cat > /home/fernando/.volumes/home-assistant/config/secrets.yaml <<'EOF'
# Use this file to store secrets like usernames and passwords.
# Learn more at https://www.home-assistant.io/docs/configuration/secrets/
some_password: welcome
EOF

# 5. Symlink the tracked config files into place
cd /home/fernando/.volumes/home-assistant/config
for f in configuration.yaml automations.yaml scripts.yaml scenes.yaml; do
  ln -s /home/fernando/HomeLab/HomeAssistant/"$f" "$f"
done

# 6. Bring up the container (this also creates/updates every other
#    service in the compose file, not just Home Assistant)
cd ~/HomeLab
docker compose up -d homeassistant
```

First boot will populate everything else HA needs (`.storage/`,
`deps/`, `tts/`, the recorder DB, default `blueprints/`) directly inside
`.volumes/home-assistant/config/`, alongside the symlinks.

## Editing config day-to-day

Just edit the files here (or through the HA UI, which writes through
the symlinks) — no restart needed unless you changed something that
requires a full HA restart anyway (e.g. `configuration.yaml`).
`docker compose up -d homeassistant` is only needed if
`docker-compose.yml` itself changes (e.g. this volume mount).

## Note

`.volumes/home-assistant/docker-compose.yaml` (singular container, no
`s` before `.yaml`) is a **stale, unused** leftover compose file —
confirmed via `docker inspect homeassistant` that the container is
actually started from `~/HomeLab/docker-compose.yml`. Safe to delete,
just hasn't been cleaned up yet.
