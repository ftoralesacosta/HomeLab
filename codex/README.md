# Codex CLI with CoreWeave models

Codex (`~/.local/bin/codex`, v0.164) talks to CoreWeave serverless inference instead of OpenAI.
No OpenAI account or login is used.

## Files

| File | What |
|---|---|
| `~/.codex/config.toml` | Main config (not in git): provider, default model, settings below |
| `~/.codex/coreweave-models.json` | The `/model` menu list. **Generated** by [`make-catalog.py`](make-catalog.py) |
| `~/.codex/<name>.config.toml` | Profiles for `codex -p <name>`: `deepseek`, `glm`, `glmflash`, `qwen`, `gemma` |
| [`make-catalog.py`](make-catalog.py) | Builds the catalog. Edit its `MODELS` list, then run it |
| [`codex-base-prompt.md`](codex-base-prompt.md) | Codex's own base instructions (from the Codex source, `codex-rs/models-manager/prompt.md`), copied into each catalog entry |

## Settings in `~/.codex/config.toml`

```toml
model = "deepseek-ai/DeepSeek-V4.1-Flash"      # default model
model_provider = "coreweave"
web_search = "disabled"                          # CoreWeave accepts only function tools; Codex's built-in web search -> HTTP 400
model_catalog_json = "/home/fernando/.codex/coreweave-models.json"   # /model menu = our CoreWeave models
model_reasoning_effort = "low"

[model_providers.coreweave]
name = "CoreWeave"
base_url = "https://api.inference.wandb.ai/v1"
env_key = "COREWEAVE_API_KEY"                    # exported from ~/HomeLab/.env by ~/.bashrc
wire_api = "responses"
```

## Use

- **`/model` inside Codex**: pick one of the five CoreWeave models (DeepSeek V4.1 Flash, GLM-5.3,
  GLM-5.3 Flash, Qwen3.8 27B, Gemma 4 31B). The choice is saved as the new default in `config.toml`.
- From the shell: `codex -p glm` (etc.), or continue the last conversation with another model:
  `codex resume --last -p glmflash`.

## Add or change a model

1. Edit `MODELS` in `make-catalog.py` (slug = exact CoreWeave model ID).
2. `python3 ~/HomeLab/codex/make-catalog.py`
3. Restart Codex **including its background process**: quit Codex, `pkill -f app-server-daemon`, start `codex`.
   (The background process reads the config once; a plain restart keeps the old menu.)

## Caveats (why this can break)

- `model_catalog_json` is not documented by OpenAI and its format changed between Codex releases.
  The catalog mirrors Codex 0.164's fallback metadata for unknown models. **After a Codex update**, if
  `/model` looks wrong or Codex errors on start, remove the `model_catalog_json` line from `config.toml`:
  everything still works with `codex -p <name>` (Codex then warns "model metadata not found", harmless).
- The catalog **replaces** Codex's list: OpenAI models no longer appear (they would not work here anyway).
- Verified 2026-10-27: `/model` → GLM-5.3 Flash → the session log shows requests sent as
  `zai-org/GLM-5.3-Flash` and the reply arrived; all five models answered via `codex exec`.
