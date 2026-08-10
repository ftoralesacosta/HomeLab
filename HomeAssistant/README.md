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

## Debug logging (and why `logs:` in configuration.yaml doesn't stick)

**Gotcha:** the per-integration debug toggle in the UI (Settings → Devices &
Services → *integration* → ⋮ → Enable debug logging) persists to
`.storage/core.logger` and is applied **at runtime**, which silently
overrides whatever `logger: logs:` sets at startup. Pinning
`homeassistant.components.lg_thinq: debug` in `configuration.yaml` therefore
*looks* like it works — it logs for the first few seconds after a restart —
and then goes dead the moment that UI toggle is used, with no error anywhere.
That's why `configuration.yaml` only sets `logger: default: warning` and
leaves per-integration levels alone.

To enable debug on demand, use the UI toggle above, or for a one-off that
doesn't persist across restarts, run the `logger.set_level` action
(Settings → Tools → Actions → YAML mode):

```yaml
action: logger.set_level
data:
  homeassistant.components.lg_thinq: debug
```

Note `lg_thinq` is push-driven (MQTT) plus an hourly energy-sensor update —
it is *not* a 5-minute poller. Quiet gaps of 45–60 minutes are normal when
the AC isn't changing, so silence alone doesn't mean logging is broken.

### What to look for

Put both directions on one timeline — that's what makes feedback loops
obvious:

```bash
# what the AC reported vs what HA sent
grep -E "async_handle_device_event|async_set_(preset|hvac|fan)_mode" home-assistant.log
```

- `async_handle_device_event … 'currentJobMode': 'COOL'` — the **device**
  reporting its state.
- `async_set_preset_mode: energy_saving` — **HA** sending a command.

A command from HA takes **~1.7–2.3 s** to land via LG's cloud, so an
unexplained device report ~2 s after an HA command is almost always HA's own
echo, not the user.

## LG AC (`climate.living`) + HomeKit — hard-won notes

**`ENERGY_SAVING` is a job mode, not a flag.** The device reports a single
field, `airConJobMode.currentJobMode`, whose values (`COOL`, `AIR_DRY`,
`FAN`, `ENERGY_SAVING`) are mutually exclusive. The `lg_thinq` integration
splits that one field into two HA concepts — `hvac_mode` *and*
`preset_mode` — and reports `hvac_mode: cool` while the unit is in
`ENERGY_SAVING`. Two HA controls therefore write to the same device field,
which is what made the feedback loop below possible.

**The Energy Saver echo loop (fixed — don't reintroduce it).**
`Energy Saver Sync` mirrors the AC's `preset_mode` into
`input_boolean.energy_saver` (which is what HomeKit shows); `Energy Saver
Control` pushes the switch's state back to the AC. Because Control triggered
on *any* change to that boolean — including Sync's own writes — every
device-originated change was echoed straight back as a command. Press Mode on
the unit to leave Energy Saver and HA's stale echo would land ~2 s later and
put it right back. Control now carries a guard condition so it only commands
the AC when the switch and the AC actually **disagree** (i.e. the user
toggled HomeKit). This also stops the restored boolean from re-asserting Eco
onto the AC on every HA restart.

**HomeKit protocol limits (not fixable in config).** Apple's `HeaterCooler`
service defines only Auto/Heat/Cool — there is **no "Fan Only" mode**. Hence
the separate `fan.virtual_ac_fan` template fan, the only way to reach
fan-only (condenser off) from HomeKit. Turning it on puts `climate.living`
into `fan_only`, so the AC tile also shows as *Active* — unavoidable, both
tiles are backed by the same entity.

**`fan.virtual_ac_fan` is the fan control for *every* mode, not just
fan-only.** It was widened deliberately, because the AC tile's own slider
can't do the job (see below). Its semantics:

| Action | Result |
| --- | --- |
| tap on, AC off | `fan_only` — never starts cooling |
| tap off | AC off, whatever mode it was in |
| slider, AC running | sets `fan_mode` only; mode is preserved (stays in cool) |
| slider, AC off | `fan_only` at that speed |
| slider to 0% | AC off |

So `state:` is *"AC is not off"*, **not** *"AC is in fan_only"* — that's what
keeps the slider usable while cooling. Don't narrow it back.

**The AC tile's own fan slider is unusable — use the Virtual AC Fan
instead.** Confirmed from `homekit` debug traces, all three independently:

- It fires **4+ `RotationSpeed` writes per drag**, each becoming its own LG
  command, and LG rejects the burst with `Fail device control`. Unlike the
  template fan, this path is HA *core* (`homekit.climate_base`) and cannot be
  debounced.
- It **never lands on 33.33** (low). Every write logged is
  `66.66666666666667` or `0`, so `low` is never even requested.
- `0` is a dead stop: HA logs `Fan does not support off, resetting to on` and
  snaps the slider back, because a climate entity's fan can't be switched off
  independently of the unit. Combined with the re-sync after each failure,
  the low detent is effectively impossible to hit.
- While the unit is Off it's still interactive, but commands fail with
  `Command not supported in POWER OFF`.

A single correctly-valued command works fine — `async_set_fan_mode: low`
succeeds in ~1.6 s — which is precisely why the debounced template fan works
and the tile doesn't. **There is no way to hide that slider:** the only
climate `entity_config` option is `type` (`thermostat` / `heater_cooler`) and
both expose fan speed; stripping `FAN_MODE` from `supported_features` would
remove it but also break `climate.set_fan_mode`, which the template fan
depends on.

**Fan speed values.** Valid HA values are `low` / `medium` / `high` (the
debug log shows `mid` — that's the integration's internal name for `medium`,
not a value to use in config). `set_percentage` delegates to
`script.virtual_ac_fan_set_speed` via non-blocking `script.turn_on`; that
script is `mode: restart` with a leading 400 ms `delay`, so a drag debounces
down to exactly one command for the final value.

**YAML trap:** `hvac_mode: off` unquoted is parsed as the boolean `false` and
silently fails validation. Always quote it: `hvac_mode: "off"`.

## Note

`.volumes/home-assistant/docker-compose.yaml` (singular container, no
`s` before `.yaml`) is a **stale, unused** leftover compose file —
confirmed via `docker inspect homeassistant` that the container is
actually started from `~/HomeLab/docker-compose.yml`. Safe to delete,
just hasn't been cleaned up yet.
