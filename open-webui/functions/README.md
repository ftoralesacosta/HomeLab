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
4. **No follow-up suggestions** under plans or reports (Open WebUI's follow-up job gets an empty list from the function); chat titles still work.

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
| `MODE` | `quick` | `quick` = cited summary; `detailed` = long multi-section report |
| `ITERATIONS` / `QUESTIONS_PER_ITERATION` | `2` / `3` | Search depth vs. time and tokens |
| `SEARCH_ENGINE` | `searxng` | Default engine; a word in the approval (*medical*, *arxiv*…) overrides it per run |
| `ATTACH_FILES` | `true` | Attach the report as PDF and Markdown downloads |
| `POLL_SECONDS` / `TIMEOUT_MINUTES` | `5` / `30` | Progress polling; runs over the limit are stopped in LDR |
| `ADMIN_ONLY` | `true` | Only Open WebUI admins can use it (each run costs tokens) |

**Why non-reasoning models:** LDR asks many short questions (for example "which of these results
are relevant?" with a small token budget). Reasoning models (DeepSeek-V4.x, Kimi-K2.6, GLM-5.3,
MiniMax-M3, gpt-oss) can spend the whole budget on hidden reasoning and return an empty answer, which
LDR treats as "nothing relevant". Tested good: `google/gemma-4-31B-it`, `meta-llama/Llama-3.3-70B-Instruct`,
`deepseek-ai/DeepSeek-V3.1`. Reasoning models also tend to leak their thinking into plans, so `PLANNER_MODEL`
defaults to Gemma too; the plan text is cleaned (leaked `</think>` text and duplicate plans
are removed) either way.
