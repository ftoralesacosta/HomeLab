# Open WebUI functions

Python plugins for Open WebUI, kept here so they are versioned and can be reinstalled.
Open WebUI stores the installed copy in its database (Admin Panel → Functions).

## Deep Research (Local Deep Research in the chat)

Two ways in, same flow:

- **Toggle (usual):** pick any model, click **Deep Research** in the chat input bar, type your topic.
  The model you picked writes the plan. ([deep_research_toggle.py](deep_research_toggle.py), a filter
  with `toggle = True`: it hands the message to the Deep Research model and remembers your model as the planner.)
- **Model:** pick **Deep Research** in the model picker. `PLANNER_MODEL` writes the plan.
  ([deep_research_model.py](deep_research_model.py), a *pipe* function, id `deep_research`; it does the actual work.)

Keep the toggle on for the whole conversation (plan, revisions, approval). Two steps, so you approve
the plan before any searching (and token spending) starts:

1. **Plan.** It replies with a research plan: sharpened question, scope, 5-8 sub-questions,
   search queries, source/bias guidance and the deliverable.
2. **Approve, revise or drop it.**
   - Reply **approve** (or *yes*, *go ahead*, *ok*, *run it*…) to run it. Add notes after it if you
     like: *"approve, focus on a $20k/yr spender"*. Notes are appended to the plan.
   - Reply anything else (*"add the Platinum card"*) and it writes a revised plan.
   - You can also edit the plan message (pencil icon) before approving: the approved plan is the
     last plan message as it is now.
   - Not interested? Just stop; nothing runs until you approve.
3. **Research.** The plan goes to Local Deep Research (`127.0.0.1:5000`), which searches through
   our SearXNG over several rounds. Progress shows live above the answer (percentage, time, current
   step); the cited report arrives as the answer (a few minutes in *quick* mode). The stop button
   also stops the job in LDR.

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
| `PLANNER_MODEL` | `google/gemma-4-31B-it` | Plan writer when you pick the Deep Research model directly (with the toggle, your chosen model plans) |
| `LDR_BASE_URL` | `http://127.0.0.1:5000` | LDR (Open WebUI runs on the host network) |
| `LDR_USERNAME` / `LDR_PASSWORD` | `openwebui` / from `.env` | LDR service account |
| `RESEARCH_MODEL` | `google/gemma-4-31B-it` | W&B model LDR uses. **Non-reasoning models only** (see below) |
| `MODE` | `quick` | `quick` = cited summary; `detailed` = long multi-section report |
| `ITERATIONS` / `QUESTIONS_PER_ITERATION` | `2` / `3` | Search depth vs. time and tokens |
| `SEARCH_ENGINE` | `searxng` | Primary engine (LDR's agent also uses Wikipedia, arXiv, OpenAlex... when useful) |
| `POLL_SECONDS` / `TIMEOUT_MINUTES` | `5` / `30` | Progress polling; runs over the limit are stopped in LDR |
| `ADMIN_ONLY` | `true` | Only Open WebUI admins can use it (each run costs tokens) |

**Why non-reasoning models:** LDR asks many short questions (for example "which of these results
are relevant?" with a small token budget). Reasoning models (DeepSeek-V4.x, Kimi-K2.6, GLM-5.3,
MiniMax-M3, gpt-oss) can spend the whole budget on hidden reasoning and return an empty answer, which
LDR treats as "nothing relevant". Tested good: `google/gemma-4-31B-it`, `meta-llama/Llama-3.3-70B-Instruct`,
`deepseek-ai/DeepSeek-V3.1`. Reasoning models also tend to leak their thinking into plans, so `PLANNER_MODEL`
defaults to Gemma too; the plan text is cleaned (leaked `</think>` text and duplicate plans
are removed) either way.
