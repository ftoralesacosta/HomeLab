# Open WebUI functions

Python plugins for Open WebUI, kept here so they are versioned and can be reinstalled.
Open WebUI stores the installed copy in its database (Admin Panel → Functions).

## Deep Research (Local Deep Research in the chat)

Two steps, so you approve the plan before any searching (and token spending) starts:

1. **Plan.** Click **Deep Research** in the chat input bar (a toggle, shown for every model),
   then type your topic. The model writes a research plan instead of an answer: a sharpened
   research question, scope, 5-8 sub-questions, search queries, source/bias guidance and the
   deliverable. Web search is off for that message. Ask for changes, or edit the message itself
   (pencil icon).
2. **Approve & run.** Click **Approve & Run Deep Research** (the button under assistant messages).
   It sends the plan in that message, including your edits, to Local Deep Research
   (`127.0.0.1:5000`), which searches through our SearXNG over several rounds. Progress shows
   above the message; the cited report is appended to the same message (about 5 minutes in
   *quick* mode). It runs in the background, so you can leave the chat; the report is saved to the
   chat when it finishes.

| File | Function id | Type |
|---|---|---|
| [deep_research_planner.py](deep_research_planner.py) | `deep_research` | Filter, `toggle = True` (the button in the input bar) |
| [execute_deep_research_action.py](execute_deep_research_action.py) | `approve_deep_research` | Action (the button under messages) |
| [install.sh](install.sh) + [install.py](install.py) | | Installs or updates both (same code path as Admin Panel → Functions) |

```bash
~/HomeLab/open-webui/functions/install.sh   # after editing a function; restarts open-webui
```

`install.sh` keeps the valves you changed in the UI and always sets `LDR_PASSWORD` from
`DEEP_RESEARCH_PASSWORD` in `.env`. Both functions are *global* (all models) and *active*.

### Valves (Admin Panel → Functions → Approve & Run Deep Research → ⚙)

| Valve | Default | Meaning |
|---|---|---|
| `LDR_BASE_URL` | `http://127.0.0.1:5000` | LDR (Open WebUI runs on the host network) |
| `LDR_USERNAME` / `LDR_PASSWORD` | `openwebui` / from `.env` | LDR service account |
| `MODEL` | `google/gemma-4-31B-it` | W&B model LDR uses. **Non-reasoning models only** (see below) |
| `MODE` | `quick` | `quick` = cited summary (~5 min); `detailed` = long multi-section report |
| `ITERATIONS` / `QUESTIONS_PER_ITERATION` | `2` / `3` | Search depth vs. time and tokens |
| `SEARCH_ENGINE` | `searxng` | Primary engine (LDR's agent also uses Wikipedia, arXiv, OpenAlex... when useful) |
| `POLL_SECONDS` / `TIMEOUT_MINUTES` | `5` / `30` | Progress polling; runs over the limit are stopped in LDR |
| `ADMIN_ONLY` | `true` | Only Open WebUI admins can run it (each run costs tokens) |

**Why a non-reasoning model:** LDR asks many short questions (for example "which of these results
are relevant?" with a small token budget). Reasoning models (DeepSeek-V4.x, Kimi-K2.6, GLM-5.3,
MiniMax-M3, gpt-oss) can spend the whole budget on hidden reasoning and return an empty answer, which
LDR treats as "nothing relevant". Tested good: `google/gemma-4-31B-it`, `meta-llama/Llama-3.3-70B-Instruct`,
`deepseek-ai/DeepSeek-V3.1`. The planner step uses whatever model you chat with.

The toggle filter has two valves: `priority` and `disable_web_search` (default on).
