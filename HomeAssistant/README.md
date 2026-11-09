# Home Assistant

The `homeassistant` container keeps its data in `${DOCKERDIR}/home-assistant/config`, mounted at
`/config`. Most of that folder is runtime data (database, logs, `.storage/`, `custom_components/`)
and is not in git.

The four files that you edit by hand are in this folder. Symlinks in the config folder point to them:

```
~/.volumes/home-assistant/config/configuration.yaml -> ~/HomeLab/HomeAssistant/configuration.yaml
                                 automations.yaml   -> ~/HomeLab/HomeAssistant/automations.yaml
                                 scripts.yaml       -> ~/HomeLab/HomeAssistant/scripts.yaml
                                 scenes.yaml        -> ~/HomeLab/HomeAssistant/scenes.yaml
```

Home Assistant and its UI editor read and write through the symlinks. The compose file mounts
`~/HomeLab/HomeAssistant` a second time, at the same path inside the container. Without that
mount, the symlinks would point to a path that does not exist in the container.

Not in git: `secrets.yaml` (now only HA's default template, not used by any config),
`blueprints/` (HA makes them again at start), and all runtime data.

## Daily use

- Edit the files here or in the HA UI.
- Restart HA only when the change needs it (most `configuration.yaml` changes do).
- Run `docker compose up -d homeassistant` only when `docker-compose.yml` changes.

## New machine

```bash
mkdir -p ~/.volumes/home-assistant/config
cd ~/.volumes/home-assistant/config
for f in configuration.yaml automations.yaml scripts.yaml scenes.yaml; do
  ln -s ~/HomeLab/HomeAssistant/"$f" "$f"
done
printf 'some_password: welcome\n' > secrets.yaml     # HA expects the file to exist
cd ~/HomeLab && docker compose up -d homeassistant
```

The first start makes everything else. To keep history and devices, restore the config folder
from the backup instead (see [backup/README.md](../backup/README.md)).

## Debug logging

Do not set per-integration levels under `logger: logs:` in `configuration.yaml`. The debug switch
in the UI (Settings → Devices & Services → *integration* → ⋮ → Enable debug logging) is applied
after start and replaces them without a warning. `configuration.yaml` sets only `default: warning`.

For debug logs, use that UI switch. For debug logs that stop at the next restart, run this action
(Settings → Developer tools → Actions, YAML mode):

```yaml
action: logger.set_level
data:
  homeassistant.components.lg_thinq: debug
```

`lg_thinq` sends updates when the AC changes, plus an energy update each hour. 45–60 minutes with
no log lines is normal when nothing changes.

To see what the AC reported and what HA sent, on one timeline:
```bash
grep -E "async_handle_device_event|async_set_(preset|hvac|fan)_mode" home-assistant.log
```
`async_handle_device_event` is the AC. `async_set_*` is HA. A command takes about 2 seconds through
LG's cloud, so an AC report about 2 seconds after an HA command is usually the echo of that command.

## LG AC (`climate.living`) and HomeKit

**Energy Saver is a mode, not a switch.** The AC has one field, `currentJobMode`, with the values
`COOL`, `AIR_DRY`, `FAN` or `ENERGY_SAVING`. The integration shows this one field as two HA
settings (`hvac_mode` and `preset_mode`), and shows `cool` while the AC is in `ENERGY_SAVING`.

**Do not bring back the Energy Saver loop.** `Energy Saver Sync` copies the AC's preset into
`input_boolean.energy_saver` (the HomeKit switch). `Energy Saver Control` sends the switch to the
AC. Control once ran on every change, including the changes from Sync, so it sent each AC change
back to the AC. Control now has a condition: it sends a command only when the switch and the AC are
different, which means a person used HomeKit. This also stops Eco from coming back at each HA restart.

**HomeKit has no "fan only" mode.** That is why `fan.virtual_ac_fan` exists. When it is on, the AC
is in `fan_only`, and the AC tile also shows *Active*, because both tiles use the same entity.

**Use the Virtual AC Fan for fan speed in every mode.** It works like this:

| Action | Result |
|---|---|
| Turn on while the AC is off | `fan_only` (never starts cooling) |
| Turn off | AC off, in any mode |
| Move the slider while the AC runs | Changes `fan_mode` only, the mode stays |
| Move the slider while the AC is off | `fan_only` at that speed |
| Slider to 0% | AC off |

Its `state:` means "AC is not off", not "AC is in fan_only". Do not change that, because the
slider must work while the AC cools.

**Do not use the fan slider on the AC tile.** HomeKit traces show three problems:
- One drag sends 4 or more speed commands, and LG rejects the burst (`Fail device control`). This
  code is in HA core, so you cannot slow it down.
- It never sends "low" (33.33). It only sends 66.67 or 0.
- 0 does not work (`Fan does not support off`), and the slider jumps back.

You cannot hide that slider. The only HomeKit option for climate entities is `type`, and both
types show fan speed. Removing `FAN_MODE` from `supported_features` would also break
`climate.set_fan_mode`, which the Virtual AC Fan needs.

**Fan speed values** are `low`, `medium` and `high`. The log shows `mid`, but that is an internal
name; do not use it. `script.virtual_ac_fan_set_speed` has `mode: restart` and starts with a 400 ms
delay, so one drag sends only one command, for the last value.

**YAML trap:** unquoted `hvac_mode: off` becomes `false` and fails without an error message.
Always write `hvac_mode: "off"`.
