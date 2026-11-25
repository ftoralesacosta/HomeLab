# Local Deep Research (LDR)

[Local Deep Research](https://github.com/LearningCircuit/local-deep-research) breaks a question into
sub-questions, searches through our SearXNG over several rounds, reads the sources, and writes a cited
Markdown report. **Open WebUI is the front door**: you run it from the chat (pick the **Deep Research** model →
plan → reply *approve*), see [../open-webui/functions/README.md](../open-webui/functions/README.md).

| Item | Value |
|---|---|
| Container | `local-deep-research` (`localdeepresearch/local-deep-research:2.0.1`), on `proxy-net` |
| Exposure | **None outside the server**: `127.0.0.1:5000` only (Open WebUI uses the host network). No subdomain, no NPM host |
| Login | LDR keeps one account: the service account `openwebui` (`DEEP_RESEARCH_USER` / `DEEP_RESEARCH_PASSWORD` in `.env`). Registration is closed |
| Search | `http://searxng:8080` (our SearXNG; JSON API on, limiter off). LDR's agent may add Wikipedia, arXiv, OpenAlex, Semantic Scholar |
| LLM | W&B Inference (`COREWEAVE_API_BASE` / `COREWEAVE_API_KEY` from `.env`), model chosen per run by the Open WebUI function (`google/gemma-4-31B-it`) |
| Depth | Every sub-agent web search also reads the top 2 result pages ([patches/read_pages.py](patches/read_pages.py), applied at container start, written for 2.0.1: check `docker logs local-deep-research \| grep read_pages` after an upgrade); page budget 12 per topic (`LDR_SEARCH_FETCH_MAX_PER_TOPIC`); PubMed open-access full texts on; 1 s pause between SearXNG searches. Details and measurements: [open-webui/functions/README.md](../open-webui/functions/README.md) |
| Data | `~/.volumes/local-deep-research/` (SQLCipher database of the account, reports, settings). In the nightly backup (caches and logs skipped) |

## Why not Authelia

LDR encrypts each account's database with a key derived from that account's password. A login done
by Authelia (OIDC or a trusted header) never gives LDR the password, so it could not open the
database; LDR 2.0.1 has no SSO. Instead nobody logs in to LDR directly: Open WebUI (Authelia OIDC)
is the only way in, and its Deep Research model uses the service account.

## Admin access to LDR's own UI

Research history, logs and settings of the service account:

```bash
ssh -L 5000:127.0.0.1:5000 fernando@ftoralesacosta.me   # then open http://localhost:5000
```

Log in as `openwebui` with `DEEP_RESEARCH_PASSWORD` from `.env`. The password encrypts the data:
if it is lost, the account's history is lost too (create a new account, update `.env`, rerun
`open-webui/functions/install.sh`).

## Settings

`LDR_<SETTING>` variables in `docker-compose.yml` set a setting **and lock it** in LDR's UI (setting key
in capitals, dots → `_`, e.g. `search.tool` → `LDR_SEARCH_TOOL`). Locked: LLM provider
(`openai_endpoint`), endpoint URL and key, search engine (`searxng`) and its URL, registration (off).
The Open WebUI function sends model, mode, iterations and questions per run.

**Use a non-reasoning model.** Reasoning models (DeepSeek-V4.x, Kimi, GLM-5.3, MiniMax) often
return empty answers to LDR's short prompts because the whole token budget goes to hidden reasoning.
Tested 2026-11-19: DeepSeek-V4.1-Flash produced 149 empty answers in 10 minutes and was stopped;
Gemma 4 31B finished a quick report in 5 min (9 KB, 31 sources: Wikipedia, journals, arXiv).

## Helper

`ldr.sh` logs in as the service account (credentials from `.env`, never printed):

```bash
local-deep-research/ldr.sh test google/gemma-4-31B-it "your question" [searxng|pubmed|arxiv]   # quick research, report in /tmp/ldr_test_report.md
local-deep-research/ldr.sh terminate                                     # stop running research
```

## Roadmap

1. **Done:** LDR deployed and tested end to end.
2. **Done:** Open WebUI *Deep Research* model (plan, reply "approve", cited report).
3. MCP: LDR's MCP server (`python -m local_deep_research.mcp`) for opencode and Hermes, using the same service account.
