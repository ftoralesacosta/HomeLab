# Open WebUI functions

Python plugins for Open WebUI, kept here so they are versioned and can be reinstalled.
Open WebUI stores the installed copy in its database (Admin Panel → Functions).

## Deep Research (Local Deep Research in the chat)

Pick any model, click **Deep Research** in the chat input bar, type your topic. The model you
picked writes the plan.

- [deep_research_toggle.py](deep_research_toggle.py): the toggle (a filter with `toggle = True`). It hands
  the message to the Deep Research model and remembers your model as the planner.
- [deep_research_model.py](deep_research_model.py): the Deep Research model (a *pipe* function, id
  `deep_research`) that does the work. It is **hidden** from the model picker (`install.sh` sets
  `meta.hidden`); hidden models still run.

Keep the toggle on for the whole conversation (plan, revisions, approval). Two steps, so you approve
the plan before any searching (and token spending) starts:

1. **Plan.** It replies with a research plan: sharpened question, scope, 5-8 sub-questions,
   search queries, source/bias guidance and the deliverable.
2. **Approve, revise or drop it.**
   - Reply **approve** (or *yes*, *go ahead*, *ok*, *run it*…) to run it. Add notes after it if you
     like: *"approve, focus on a $20k/yr spender"*. Notes are appended to the plan.
   - The plan ends with a short, friendly menu of these choices (built into the function, so it looks
     the same whatever model wrote the plan).
   - **Pick the sources** with a word in the approval:

     | You write | Searched (LDR engine) |
     |---|---|
     | *approve* | the web through SearXNG (default, valve `SEARCH_ENGINE`) |
     | *approve medical* (or *pubmed*, *clinical*, *journals*, *peer-reviewed*, *health*) | **PubMed**: peer-reviewed biomedical and medical journals (NCBI, no API key needed) |
     | *approve arxiv* / *preprints* | arXiv preprints |
     | *approve wikipedia* | Wikipedia |

   - **Depth:** add *thorough* (or *detailed*, *in-depth*) for the long report: LDR's `detailed` mode
     writes it section by section with extra searches per section. Combine freely: *approve medical thorough*.

     LDR's agent may still consult other sources when a question needs them; the chosen engine is the main one.
   - Reply anything else (*"add the Platinum card"*) and it writes a revised plan.
   - You can also edit the plan message (pencil icon) before approving: the approved plan is the
     last plan message as it is now.
   - Not interested? Just stop; nothing runs until you approve.
3. **Research.** The plan goes to Local Deep Research (`127.0.0.1:5000`). While it runs you see:
   - a **task checklist** (Open WebUI's `chat:message:tasks`) that ticks off: read the plan → search
     (questions investigated, searches) → read the sources (how many found) → write the report → prepare downloads;
   - status lines with the **search questions as chips**, and at the end the **list of sources used**.

   The cited report arrives as the answer (a few minutes in *quick* mode), with **PDF** and
   **Markdown** downloads attached to the message and linked under the report. The PDF comes from
   LDR's own exporter; both files are stored in Open WebUI's file storage. The stop button also
   stops the job in LDR.
4. **No follow-up suggestions** under plans or reports. Open WebUI generates them with the model recorded on the answer, so the function records itself (`deep_research`) on its answers and returns an empty list for that job. After a refresh those answers are labelled *Deep Research*. Chat titles still work.

Why the research runs as a model (the toggle just routes to it) and not as a button under the message: Open WebUI 0.11 runs action buttons outside the chat request, so their
live updates and late results were unreliable. A model runs inside the normal chat request (like web
search), so progress and the answer behave like any other reply.

```bash
~/HomeLab/open-webui/functions/install.sh   # after editing the function; restarts open-webui
```

`install.sh` keeps valves you changed in the UI, always sets `LDR_PASSWORD` from
`DEEP_RESEARCH_PASSWORD` in `.env`, and removes the v1 action button.

### Valves (Admin Panel → Functions → Deep Research → ⚙)

| Valve | Default | Meaning |
|---|---|---|
| `PLANNER_MODEL` | `google/gemma-4-31B-it` | Fallback plan writer if no model is passed (with the toggle, your chosen model plans) |
| `LDR_BASE_URL` | `http://127.0.0.1:5000` | LDR (Open WebUI runs on the host network) |
| `LDR_USERNAME` / `LDR_PASSWORD` | `openwebui` / from `.env` | LDR service account |
| `RESEARCH_MODEL` | `google/gemma-4-31B-it` | W&B model LDR uses. **Non-reasoning models only** (see below) |
| `MODE` | `quick` | Default report type; *approve thorough* picks `detailed` for one run |
| `ITERATIONS` / `QUESTIONS_PER_ITERATION` | `2` / `3` | Search depth vs. time and tokens |
| `SEARCH_ENGINE` | `searxng` | Default engine; a word in the approval (*medical*, *arxiv*…) overrides it per run |
| `ATTACH_FILES` | `true` | Attach the report as PDF and Markdown downloads |
| `POLL_SECONDS` / `TIMEOUT_MINUTES` | `5` / `60` | Progress polling; runs over the limit are stopped in LDR |
| `ADMIN_ONLY` | `true` | Only Open WebUI admins can use it (each run costs tokens) |

**Why non-reasoning models:** LDR asks many short questions (for example "which of these results
are relevant?" with a small token budget). Reasoning models (DeepSeek-V4.x, Kimi-K2.6, GLM-5.3,
MiniMax-M3, gpt-oss) can spend the whole budget on hidden reasoning and return an empty answer, which
LDR treats as "nothing relevant". Tested good: `google/gemma-4-31B-it`, `meta-llama/Llama-3.3-70B-Instruct`,
`deepseek-ai/DeepSeek-V3.1`. Reasoning models also tend to leak their thinking into plans, so `PLANNER_MODEL`
defaults to Gemma too; the plan text is cleaned (leaked `</think>` text and duplicate plans
are removed) either way.

### Depth: what every run does (tested 2026-11-25)

LDR's research agent decides by itself when it has enough. Left alone, Gemma stopped after one round of
searches and wrote from search-result snippets. Three changes apply to **every** run:

1. **Instructions in front of the plan** (`DEPTH_INSTRUCTIONS` in the function): research each
   sub-question separately (LDR's parallel subtopic agents), open and read key sources, check
   important facts in two sources, do not stop after the first round.
2. **Page-reading budget** raised from 2 to 12 per topic (`LDR_SEARCH_FETCH_MAX_PER_TOPIC` in compose).
3. **Pages are always read** ([local-deep-research/patches/read_pages.py](../../local-deep-research/patches/read_pages.py),
   applied when the LDR container starts). Opening a page is normally the model's choice, and Gemma never
   made it, even when told to. The patch makes every sub-agent web search also read the top 2 result
   pages with LDR's own `fetch_content` (it keeps only the passages relevant to the search) and hand
   those excerpts to the model with the snippets. Written for LDR 2.0.1; on an image upgrade check
   `docker logs local-deep-research | grep read_pages` says "applied" (it skips itself, with a
   warning, if LDR's code changed).

Same plan (heat pump vs gas furnace), measured:

| | `approve` (before page reading) | `approve` (with page reading) | `approve thorough` (before page reading) |
|---|---|---|---|
| Time | 65 s | 2.9 min | 10.6 min |
| Questions researched | 5 | 5 | 14 (86 searches) |
| Pages read in full | 0 | 36 | 0 |
| Sources gathered | 181 | 404 | 780 |
| Citations in the report | 40 | 277 | 179 |
| Report | 11.5 KB | 40 KB | 108 KB |

Tried and dropped:
- `LDR_SEARCH_SNIPPETS_ONLY=false` (read every result page in full): the full pages crowded the model,
  24 sources and 7 citations instead of 181 and 40.
- Telling Gemma to open pages (in the plan, in each subtopic, and in LDR's sub-agent prompt): 0 or 1 pages read.
- LDR's `source-based` strategy (reads pages without asking the model): it searched for words from the
  plan's wording ("according"), and the report was about dictionary entries.

PubMed open-access full texts (`LDR_SEARCH_ENGINE_WEB_PUBMED_DEFAULT_PARAMS_GET_FULL_TEXT`, up to 3 per
search) are on for *approve medical*.

SearXNG: research runs make dozens of searches, and SearXNG's default engines (Brave, DuckDuckGo, Google)
started refusing them ("too many requests"). [searxng/settings.yml](../../searxng/settings.yml) turns on
more engines (Bing, Google, Qwant, Yahoo, DuckDuckGo, Yep) and LDR pauses 1 s between searches. SearXNG
suspends an engine that refuses and retries it later.

### Research models that work with LDR (probed 2026-11-25)

LDR needs direct answers to many short prompts; models that think silently first return empty answers.

| Model | Hidden reasoning | Notes |
|---|---|---|
| `google/gemma-4-31B-it` | none | **Current default.** Fast, good citations |
| `meta-llama/Llama-3.3-70B-Instruct` | none | Larger, strong general knowledge; slower |
| `deepseek-ai/DeepSeek-V3.1` | none | Largest of the usable ones (671B MoE); best reasoning, higher cost |
| `google/gemma-4-26B-A4B-it` | none | Small and cheap (4B active); for quick runs |
| Kimi-K2.7-Code, Nemotron 3/3.5, Qwen3.8, DeepSeek-V4.x, GLM-5.x, Beam, MiniMax, gpt-oss | yes | Not suitable for `RESEARCH_MODEL` |

Change it in the function's valves (`RESEARCH_MODEL`).
