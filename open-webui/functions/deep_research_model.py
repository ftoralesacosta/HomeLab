"""
title: Deep Research
author: homelab (HomeLab/open-webui/functions)
version: 2.2.0
required_open_webui_version: 0.6.0
description: The Deep Research flow (as a model, and behind the Deep Research toggle). Send a topic and it replies with a research plan. Reply "approve" (optionally with notes) to run it in Local Deep Research with live progress and get a cited report; anything else revises the plan.
"""

import asyncio
import re
import time
from typing import Literal

import aiohttp
from pydantic import BaseModel, Field

PLAN_HEADING = "## Research plan"
REPORT_HEADING = "## Deep research report"
APPROVE_RE = re.compile(
    r"^\s*(approve[ds]?|approval|go( ahead)?|run( it)?|start|yes|yep|ok(ay)?|do it|lgtm|looks good|proceed|execute)\b[\s,.:;!-]*",
    re.I,
)

# words in the approval message that pick the main source (LDR search engine)
SOURCE_WORDS = [
    (re.compile(r"\b(pub ?med|medical|medicine|clinical|biomedical|health|journals?|peer[- ]reviewed)\b", re.I), "pubmed",
     "PubMed (peer-reviewed biomedical and medical literature)"),
    (re.compile(r"\b(arxiv|preprints?)\b", re.I), "arxiv", "arXiv (preprints: physics, CS, math, quantitative biology)"),
    (re.compile(r"\b(wikipedia|encyclop(a)?edia)\b", re.I), "wikipedia", "Wikipedia"),
    (re.compile(r"\b(web|searx(ng)?|general)\b", re.I), "searxng", "the web (SearXNG)"),
]

FILLER_RE = re.compile(r"[\W_]*((please|pls|thanks|thank you|and|&|run|do|go|it|the|this|that|research|plan|now|start|only|use|using|with|search|sources?|on)[\W_]*)*", re.I)

PLANNER_PROMPT = """You are a research planner. Do not answer the user's question and do not search the web.
Turn the user's topic into a research plan that a separate deep-research engine will execute.
If the user gives feedback on an earlier plan, reply with the full revised plan.
The reply is the plan only, written once, in this Markdown structure:

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
- Prefer: ...
- Treat with care: ...
- Bias checks: ...

**Deliverable:** what the final report should contain (sections, length, tables, recommendations).

Keep it concise and use the user's language. Do not add anything before or after the plan."""

FOOTER = ("\n\n---\n_Reply **approve** to run this plan on the web, or **approve medical** to search PubMed journals "
          "(notes allowed, e.g. \"approve, focus on X\"). Or tell me what to change, or edit this message first._")


def clean_plan(text: str) -> str:
    """Drop leaked reasoning and keep only the last copy of the plan, without the footer."""
    text = text or ""
    text = re.sub(r"<details[^>]*>.*?</details>", "", text, flags=re.S)
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    text = text.split("\n\n" + REPORT_HEADING)[0].split("\n---\n## Deep research report")[0]
    if PLAN_HEADING in text:
        text = PLAN_HEADING + text.rsplit(PLAN_HEADING, 1)[1]
    text = re.sub(r"\n-{3,}\s*\n_Reply \*\*approve\*\*.*$", "", text, flags=re.S)
    text = re.sub(r"\n-{3,}\s*\n_?Edit anything above.*$", "", text, flags=re.S)
    return text.strip()


def text_of(content) -> str:
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


class Pipe:
    class Valves(BaseModel):
        PLANNER_MODEL: str = Field(default="google/gemma-4-31B-it",
                                   description="Plan writer when you pick the Deep Research model directly. With the toggle, the model you chose writes the plan")
        LDR_BASE_URL: str = Field(default="http://127.0.0.1:5000", description="Local Deep Research URL (Open WebUI runs on the host network)")
        LDR_USERNAME: str = Field(default="openwebui", description="LDR service account (DEEP_RESEARCH_USER in ~/HomeLab/.env)")
        LDR_PASSWORD: str = Field(default="", description="LDR service account password (DEEP_RESEARCH_PASSWORD in ~/HomeLab/.env)",
                                  json_schema_extra={"input": {"type": "password"}})
        RESEARCH_MODEL: str = Field(default="google/gemma-4-31B-it",
                                    description="W&B model LDR uses. Non-reasoning only: reasoning models return empty answers to LDR's short prompts")
        MODE: Literal["quick", "detailed"] = Field(default="quick", description="quick = cited summary (minutes); detailed = long multi-section report")
        ITERATIONS: int = Field(default=2, ge=1, le=8, description="Search rounds")
        QUESTIONS_PER_ITERATION: int = Field(default=3, ge=1, le=8, description="Follow-up questions per round")
        SEARCH_ENGINE: str = Field(default="searxng", description="Default LDR search engine (\"approve medical\" switches a run to pubmed)")
        POLL_SECONDS: int = Field(default=5, ge=2, le=60)
        TIMEOUT_MINUTES: int = Field(default=30, ge=5, le=180)
        ADMIN_ONLY: bool = Field(default=True, description="Only Open WebUI admins may use it (each run costs LLM tokens)")

    def __init__(self):
        self.valves = self.Valves()

    async def pipe(self, body: dict, __user__: dict | None = None, __request__=None, __event_emitter__=None):
        emit = __event_emitter__

        async def status(text: str, done: bool = False):
            if emit:
                await emit({"type": "status", "data": {"description": text, "done": done}})

        if self.valves.ADMIN_ONLY and (__user__ or {}).get("role") != "admin":
            return "Deep Research is limited to admins."

        msgs = [m for m in (body.get("messages") or []) if m.get("role") in ("user", "assistant")]
        last_user = text_of(msgs[-1].get("content")) if msgs and msgs[-1].get("role") == "user" else ""
        plan_msg = next((m for m in reversed(msgs[:-1]) if m.get("role") == "assistant" and PLAN_HEADING in text_of(m.get("content"))), None)

        m = APPROVE_RE.match(last_user)
        if plan_msg and m:
            notes = last_user[m.end():].strip()
            engine, label = self.valves.SEARCH_ENGINE, ""
            rest = notes
            for rx, eng, desc in SOURCE_WORDS:  # "approve medical" / "approve, pubmed only" -> PubMed
                if rx.search(notes):
                    engine, label = eng, desc
                    rest = rx.sub("", notes)
                    break
            if FILLER_RE.fullmatch(rest):  # nothing but filler ("please do the research plan", "only") -> no notes
                notes = ""
            plan = clean_plan(text_of(plan_msg.get("content")))
            if label:
                plan += f"\n\n**Primary source:** {label}. Base the findings on it and cite it."
            if notes:
                plan += f"\n\n**Additional instructions from the user:** {notes}"
            return await self._research(plan, status, engine)
        # With the toggle, the model the user picked writes the plan; picking "Deep Research" directly uses PLANNER_MODEL.
        planner = body.get("deep_research_planner_model") or self.valves.PLANNER_MODEL
        return await self._plan(msgs, __user__, __request__, status, planner)

    # ---------- step 1: plan ----------
    async def _plan(self, msgs, user: dict, request, status, planner: str) -> str:
        from open_webui.models.users import Users
        from open_webui.utils.chat import generate_chat_completion

        await status(f"Writing the research plan ({planner.split('/')[-1]})…")
        convo = []
        for m in msgs:  # previous plans stay (so feedback revises them); reports are dropped
            content = text_of(m.get("content"))
            if m["role"] == "assistant":
                content = clean_plan(content) if PLAN_HEADING in content else content.split(REPORT_HEADING)[0].strip()
                if not content:
                    continue
            convo.append({"role": m["role"], "content": content})
        user_obj = await Users.get_user_by_id(user["id"])
        res = await generate_chat_completion(request, {"model": planner, "stream": False,
                                                       "messages": [{"role": "system", "content": PLANNER_PROMPT}] + convo},
                                             user_obj, bypass_filter=True)
        if hasattr(res, "body"):  # JSONResponse
            import json
            res = json.loads(res.body)
        text = ((res or {}).get("choices") or [{}])[0].get("message", {}).get("content") or ""
        plan = clean_plan(text)
        await status("Plan ready — reply “approve” to run it", True)
        if PLAN_HEADING not in plan:
            return text.strip() or "The planner returned nothing. Try again, or change PLANNER_MODEL in the function's valves."
        return plan + FOOTER

    # ---------- step 2: research ----------
    async def _research(self, plan: str, status, engine: str) -> str:
        v = self.valves
        if not v.LDR_PASSWORD:
            return "Deep Research is not configured: set LDR_PASSWORD in the function's valves."
        base = v.LDR_BASE_URL.rstrip("/")
        query = ("Carry out deep research following this approved research plan. Answer the research question, "
                 "use the sub-questions and search queries as guidance, respect the scope and source guidance, "
                 "and produce the requested deliverable with citations.\n\n" + plan)[:9500]
        t0 = time.time()
        await status(f"Deep research: starting ({engine})…")
        try:
            # unsafe=True: aiohttp otherwise drops cookies set by an IP-address host (127.0.0.1)
            async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True),
                                             timeout=aiohttp.ClientTimeout(total=120)) as s:
                csrf = await self._login(s, base)
                async with s.post(f"{base}/api/start_research", headers={"X-CSRF-Token": csrf}, json={
                    "query": query, "mode": v.MODE, "model_provider": "openai_endpoint", "model": v.RESEARCH_MODEL,
                    "search_engine": engine, "search_engines": [engine],
                    "iterations": v.ITERATIONS, "questions_per_iteration": v.QUESTIONS_PER_ITERATION}) as r:
                    data = await r.json(content_type=None)
                rid = (data or {}).get("research_id")
                if not rid:
                    raise RuntimeError(f"LDR did not start the research: {str(data)[:200]}")
                last, last_at, st = None, 0.0, {}
                try:
                    while True:
                        await asyncio.sleep(v.POLL_SECONDS)
                        async with s.get(f"{base}/api/research/{rid}/status") as r:
                            st = await r.json(content_type=None) or {}
                        state, pct = st.get("status"), st.get("progress") or 0
                        if state in ("completed", "failed", "suspended", "error", "cancelled"):
                            break
                        note = await self._latest_milestone(s, base, rid)
                        if (pct, note) != last or time.time() - last_at >= 30:
                            el = int(time.time() - t0)
                            await status(f"Deep research: {pct}% · {el // 60}m{el % 60:02d}s" + (f" · {note}" if note else ""))
                            last, last_at = (pct, note), time.time()
                        if time.time() - t0 > v.TIMEOUT_MINUTES * 60:
                            raise TimeoutError(f"timed out after {v.TIMEOUT_MINUTES} min")
                except (asyncio.CancelledError, TimeoutError):
                    # stop button in Open WebUI, or our timeout: stop the job in LDR too
                    async with s.post(f"{base}/api/terminate/{rid}", headers={"X-CSRF-Token": csrf}, json={}):
                        pass
                    raise
                if state != "completed":
                    raise RuntimeError(f"LDR research {state}: {str(st.get('error') or st.get('message') or '')[:300]}")
                async with s.get(f"{base}/api/report/{rid}") as r:
                    rep = await r.json(content_type=None) or {}
                report = (rep.get("content") or rep.get("summary") or "").strip()
                if not report:
                    raise RuntimeError("LDR finished but returned an empty report")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            await status(f"Deep research failed: {str(e)[:200]}", True)
            return f"Deep research failed: {e}"
        mins, secs = divmod(int(time.time() - t0), 60)
        await status(f"Deep research complete ({mins}m{secs:02d}s)", True)
        return (f"{REPORT_HEADING}\n\n{report}\n\n"
                f"<sub>Local Deep Research · {engine} · {v.RESEARCH_MODEL} · {v.MODE} · {mins}m{secs:02d}s · id {rid}</sub>")

    async def _login(self, s: aiohttp.ClientSession, base: str) -> str:
        async with s.get(f"{base}/auth/login") as r:
            page = await r.text()
        m = re.search(r'name="csrf_token"[^>]*value="([^"]*)"', page)
        if not m:
            raise RuntimeError("LDR login page has no CSRF token (is LDR running?)")
        async with s.post(f"{base}/auth/login", data={"username": self.valves.LDR_USERNAME, "password": self.valves.LDR_PASSWORD,
                                                       "remember": "false", "csrf_token": m.group(1)}) as r:
            if "/auth/login" in str(r.url):
                raise RuntimeError("LDR login failed (check LDR_USERNAME / LDR_PASSWORD, or the login rate limit)")
        async with s.get(f"{base}/auth/csrf-token") as r:
            return (await r.json(content_type=None))["csrf_token"]

    @staticmethod
    async def _latest_milestone(s: aiohttp.ClientSession, base: str, rid: str) -> str:
        try:
            async with s.get(f"{base}/api/research/{rid}/logs?limit=150") as r:
                logs = await r.json(content_type=None) or []
            for row in reversed(logs if isinstance(logs, list) else []):
                if str(row.get("log_type", "")).upper() == "MILESTONE" and row.get("message"):
                    return str(row["message"])[:120]
        except Exception:
            pass
        return ""
