# Local Deep Research (LDR)

https://research.ftoralesacosta.me runs [Local Deep Research](https://github.com/LearningCircuit/local-deep-research):
it breaks a question into sub-questions, searches the web through our SearXNG over several rounds,
reads the sources, and writes a cited Markdown report.

| Item | Value |
|---|---|
| Container | `local-deep-research` (`localdeepresearch/local-deep-research:2.0.1`), on `proxy-net` |
| Ports | `127.0.0.1:5000` only (for Open WebUI, which uses the host network). Outside: NPM host `research.` |
| Access | Authelia gate, `admin` group, 2FA. Then LDR's own login (one account per person) |
| Search | `http://searxng:8080` (our SearXNG; JSON API on, limiter off) |
| LLM | W&B Inference, the same OpenAI-compatible endpoint as Open WebUI and Hermes (`COREWEAVE_API_BASE` / `COREWEAVE_API_KEY` from `.env`) |
| Data | `~/.volumes/local-deep-research/` (per-user SQLCipher databases, reports, settings). In the nightly backup (caches and logs skipped) |

## Settings

`LDR_<SETTING>` variables in `docker-compose.yml` set a setting **and lock it** in LDR's UI
(the name is the setting key in capitals, dots → `_`, e.g. `search.tool` → `LDR_SEARCH_TOOL`).
Locked: LLM provider (`openai_endpoint`), endpoint URL and key, search engine (`searxng`) and its URL.
Everything else is per user, in LDR's **Settings**:

- **LLM → Model**: pick one from the endpoint (24 models). Research makes many calls, so a fast,
  cheap model is the sensible default (e.g. `deepseek-ai/DeepSeek-V4.1-Flash` or `Qwen/Qwen3.6-35B-A3B`);
  use a bigger one when quality matters more than cost.
- **Search → iterations / questions per iteration**: depth vs. time and tokens (defaults 3 × 1).

## Accounts

Each person registers their own account (data is encrypted with their password, so a forgotten
password cannot be recovered). Registration is open while the first accounts are made
(`LDR_APP_ALLOW_REGISTRATIONS: "true"`); set it to `"false"` and run `docker compose up -d local-deep-research` afterwards.

## Roadmap

1. **Done:** LDR deployed, own web UI behind Authelia.
2. Open WebUI: a *Deep Research* toggle (Filter: the model writes a research plan) and an
   *Approve & Run Deep Research* button (Action: sends the plan to LDR on `127.0.0.1:5000`,
   streams progress, posts the cited report into the chat).
3. MCP: LDR's MCP server (`python -m local_deep_research.mcp`) for opencode and Hermes.
