"""
title: Deep Research
author: homelab (HomeLab/open-webui/functions)
version: 1.0.0
required_open_webui_version: 0.6.0
description: Toggle in the chat bar. While it is on, the model writes a structured research plan instead of an answer (no web search yet). Edit the plan if you like, then click "Approve & Run Deep Research" under the message.
"""

from pydantic import BaseModel, Field

PLANNER_PROMPT = """You are a research planner. Do NOT answer the user's question and do NOT search the web.
Turn the user's topic into a research plan that a separate deep-research engine will execute.
If the user is giving feedback on an earlier plan, output the full revised plan.

Output exactly this Markdown structure, nothing before it and nothing after the final line:

## Research plan

**Research question:** one precise, answerable question (sharpened from the user's topic).

**Scope**
- In scope: ...
- Out of scope: ...
- Time period / geography / audience: ... (state assumptions if the user did not say)

**Sub-questions** (5-8, each answerable on its own)
1. ...

**Search queries** (8-12 short, specific web search queries; include synonyms, key names, and at least one query for opposing evidence)
- ...

**Source guidance**
- Prefer: ... (e.g. peer-reviewed papers, official statistics, primary documents)
- Treat with care: ... (e.g. vendor marketing, partisan outlets, undated pages)
- Bias checks: ... (perspectives or counter-arguments that must be covered)

**Deliverable:** what the final report should contain (sections, length, tables, recommendations).

---
_Edit anything above if needed, then click **Approve & Run Deep Research** below this message._

Keep it concise. Use the user's language."""

# magnifying glass over a page (shown on the toggle button)
ICON = (
    "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' "
    "stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'>"
    "<path d='M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h5'/><path d='M8 8h6M8 12h3'/>"
    "<circle cx='16.5' cy='15.5' r='3.5'/><path d='m21 20-2-2'/></svg>"
)


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0, description="Filter order (lower runs first)")
        disable_web_search: bool = Field(
            default=True, description="Turn off Open WebUI web search while planning (the plan is executed later by Local Deep Research)"
        )

    def __init__(self):
        self.valves = self.Valves()
        self.toggle = True  # shows a "Deep Research" toggle button in the chat input bar
        self.icon = ICON

    async def inlet(self, body: dict, __user__: dict | None = None) -> dict:
        messages = body.get("messages") or []
        if messages and messages[0].get("role") == "system":
            existing = messages[0].get("content") or ""
            if PLANNER_PROMPT not in existing:
                messages[0]["content"] = PLANNER_PROMPT + ("\n\n" + existing if existing else "")
        else:
            messages.insert(0, {"role": "system", "content": PLANNER_PROMPT})
        body["messages"] = messages
        if self.valves.disable_web_search:
            features = body.get("features") or {}
            features["web_search"] = False
            body["features"] = features
        return body
