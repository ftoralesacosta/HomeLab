"""
title: Approve & Run Deep Research
author: homelab (HomeLab/open-webui/functions)
version: 1.0.1
required_open_webui_version: 0.6.0
description: Sends the research plan in this message (including your edits) to Local Deep Research, shows live progress, and appends the cited report to the message.
icon_url: data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='11' cy='11' r='7'/><path d='m20 20-3.5-3.5'/><path d='m8.5 11 2 2 4-4'/></svg>
"""

import asyncio
import re
import time
from typing import Literal

import aiohttp
from pydantic import BaseModel, Field

REPORT_MARKER = "\n\n---\n\n## Deep research report"
FOOTER_RE = re.compile(r"\n-{3,}\s*\n_?Edit anything above.*$", re.S)
_TASKS: set = set()  # keep background tasks referenced until they finish


class Action:
    class Valves(BaseModel):
        LDR_BASE_URL: str = Field(default="http://127.0.0.1:5000", description="Local Deep Research URL (Open WebUI runs on the host network)")
        LDR_USERNAME: str = Field(default="openwebui", description="LDR service account (DEEP_RESEARCH_USER in ~/HomeLab/.env)")
        LDR_PASSWORD: str = Field(default="", description="LDR service account password (DEEP_RESEARCH_PASSWORD in ~/HomeLab/.env)",
                                  json_schema_extra={"input": {"type": "password"}})
        MODEL: str = Field(default="google/gemma-4-31B-it", description="LLM on the W&B endpoint. Use a non-reasoning model: reasoning models return empty answers to LDR's short prompts")
        MODE: Literal["quick", "detailed"] = Field(default="quick", description="quick = cited summary (~5 min); detailed = long multi-section report (slower, more tokens)")
        ITERATIONS: int = Field(default=2, ge=1, le=8, description="Search rounds")
        QUESTIONS_PER_ITERATION: int = Field(default=3, ge=1, le=8, description="Follow-up questions per round")
        SEARCH_ENGINE: str = Field(default="searxng", description="Primary LDR search engine")
        POLL_SECONDS: int = Field(default=5, ge=2, le=60)
        TIMEOUT_MINUTES: int = Field(default=30, ge=5, le=180)
        ADMIN_ONLY: bool = Field(default=True, description="Only Open WebUI admins may run it (each run costs LLM tokens)")

    def __init__(self):
        self.valves = self.Valves()

    # ---------- Open WebUI entry point ----------
    async def action(self, body: dict, __user__: dict | None = None, __event_emitter__=None, __event_call__=None):
        emit = __event_emitter__ or (lambda *_a, **_k: asyncio.sleep(0))

        async def status(text: str, done: bool = False):
            await emit({"type": "status", "data": {"description": text, "done": done}})

        if self.valves.ADMIN_ONLY and (__user__ or {}).get("role") != "admin":
            await status("Deep research is limited to admins.", True)
            return
        if not self.valves.LDR_PASSWORD:
            await status("Deep research is not configured: set LDR_PASSWORD in the function's valves.", True)
            return

        plan = self._plan_from(body)
        if len(plan.strip()) < 20:
            await status("No research plan found in this message.", True)
            return

        await status("Deep research: starting…")
        # Run in the background: the button's HTTP request would otherwise sit open for minutes
        # (and Cloudflare cuts requests after 100 s). Progress and the report arrive over the socket.
        task = asyncio.create_task(self._run(plan, emit, status))
        _TASKS.add(task)
        task.add_done_callback(_TASKS.discard)

    # ---------- helpers ----------
    @staticmethod
    def _plan_from(body: dict) -> str:
        msgs = body.get("messages") or []
        target = next((m for m in msgs if m.get("id") and m.get("id") == body.get("id")), None)
        if target is None:
            target = next((m for m in reversed(msgs) if m.get("role") == "assistant"), {})
        content = target.get("content") or ""
        if isinstance(content, list):  # multimodal content parts
            content = "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
        content = content.split(REPORT_MARKER)[0]              # re-run: drop an earlier report
        content = re.sub(r"<details[^>]*>.*?</details>", "", content, flags=re.S)  # reasoning blocks
        return FOOTER_RE.sub("", content).strip()

    async def _run(self, plan: str, emit, status):
        v = self.valves
        base = v.LDR_BASE_URL.rstrip("/")
        query = ("Carry out deep research following this approved research plan. Answer the research question, "
                 "use the sub-questions and search queries as guidance, respect the scope and source guidance, "
                 "and produce the requested deliverable with citations.\n\n" + plan)[:9500]
        t0 = time.time()
        timeout = aiohttp.ClientTimeout(total=120)
        try:
            # unsafe=True: aiohttp otherwise drops cookies set by an IP-address host (127.0.0.1)
            async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True), timeout=timeout) as s:
                csrf = await self._login(s, base)
                async with s.post(f"{base}/api/start_research", headers={"X-CSRF-Token": csrf}, json={
                    "query": query, "mode": v.MODE, "model_provider": "openai_endpoint", "model": v.MODEL,
                    "search_engine": v.SEARCH_ENGINE, "search_engines": [v.SEARCH_ENGINE],
                    "iterations": v.ITERATIONS, "questions_per_iteration": v.QUESTIONS_PER_ITERATION}) as r:
                    data = await r.json(content_type=None)
                rid = (data or {}).get("research_id")
                if not rid:
                    raise RuntimeError(f"LDR did not start the research: {str(data)[:200]}")

                last, last_at, st = None, 0.0, {}
                while True:
                    await asyncio.sleep(v.POLL_SECONDS)
                    async with s.get(f"{base}/api/research/{rid}/status") as r:
                        st = await r.json(content_type=None) or {}
                    state, pct = st.get("status"), st.get("progress") or 0
                    if state in ("completed", "failed", "suspended", "error", "cancelled"):
                        break
                    note = await self._latest_milestone(s, base, rid)
                    elapsed = int(time.time() - t0)
                    key = (pct, note)
                    # Open WebUI stores every status in the chat: post on change, else every 30 s
                    if key != last or time.time() - last_at >= 30:
                        await status(f"Deep research: {pct}% · {elapsed // 60}m{elapsed % 60:02d}s" + (f" · {note}" if note else ""))
                        last, last_at = key, time.time()
                    if time.time() - t0 > v.TIMEOUT_MINUTES * 60:
                        async with s.post(f"{base}/api/terminate/{rid}", headers={"X-CSRF-Token": csrf}, json={}):
                            pass
                        raise RuntimeError(f"timed out after {v.TIMEOUT_MINUTES} min (stopped in LDR)")

                if state != "completed":
                    raise RuntimeError(f"LDR research {state}: {str(st.get('error') or st.get('message') or '')[:300]}")
                async with s.get(f"{base}/api/report/{rid}") as r:
                    rep = await r.json(content_type=None) or {}
                report = rep.get("content") or rep.get("summary") or ""
                if not report.strip():
                    raise RuntimeError("LDR finished but returned an empty report")

            mins, secs = divmod(int(time.time() - t0), 60)
            await emit({"type": "message", "data": {"content":
                f"{REPORT_MARKER}\n\n{report.strip()}\n\n"
                f"<sub>Local Deep Research · {v.MODEL} · {v.MODE} · {mins}m{secs:02d}s · id {rid}</sub>\n"}})
            await status(f"Deep research complete ({mins}m{secs:02d}s)", True)
        except Exception as e:  # report every failure in the chat instead of failing silently
            await status(f"Deep research failed: {str(e)[:200]}", True)

    async def _login(self, s: aiohttp.ClientSession, base: str) -> str:
        async with s.get(f"{base}/auth/login") as r:
            page = await r.text()
        m = re.search(r'name="csrf_token"[^>]*value="([^"]*)"', page)
        if not m:
            raise RuntimeError("LDR login page has no CSRF token (is LDR running?)")
        async with s.post(f"{base}/auth/login", data={"username": self.valves.LDR_USERNAME,
                                                       "password": self.valves.LDR_PASSWORD,
                                                       "remember": "false", "csrf_token": m.group(1)}) as r:
            if "/auth/login" in str(r.url):
                raise RuntimeError("LDR login failed (check LDR_USERNAME / LDR_PASSWORD)")
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
