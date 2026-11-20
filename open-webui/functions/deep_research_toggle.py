"""
title: Deep Research (toggle)
author: homelab (HomeLab/open-webui/functions)
version: 2.0.0
required_open_webui_version: 0.6.0
description: Deep Research button in the chat bar. With it on, your message goes to the Deep Research flow and the model you picked writes the research plan. Reply "approve" to run it in Local Deep Research (live progress, cited report).
"""

from pydantic import BaseModel, Field

PIPE_ID = "deep_research"   # the Deep Research model (deep_research_model.py)
PLANNER_KEY = "deep_research_planner_model"

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

    def __init__(self):
        self.valves = self.Valves()
        self.toggle = True  # adds the "Deep Research" toggle to the chat input bar
        self.icon = ICON

    async def inlet(self, body: dict, __user__: dict | None = None) -> dict:
        # Hand the message to the Deep Research model; the chosen model becomes the planner.
        # Open WebUI runs filters before it resolves the model, so changing body["model"] reroutes the request.
        model = body.get("model")
        if model and model != PIPE_ID:
            body[PLANNER_KEY] = model
            body["model"] = PIPE_ID
            features = body.get("features") or {}
            features["web_search"] = False  # the plan is executed by Local Deep Research, not web search
            body["features"] = features
        return body
