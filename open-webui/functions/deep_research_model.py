"""
title: Deep Research
author: homelab (HomeLab/open-webui/functions)
version: 3.5.0
required_open_webui_version: 0.6.0
description: The Deep Research flow behind the Deep Research toggle. Send a topic and it replies with a research plan; reply "approve" (or "approve medical" for PubMed) to run it in Local Deep Research with a live task checklist, then get a cited report plus PDF and Markdown downloads.
"""

import asyncio
import io
import re
import time
import uuid
from typing import Literal

import aiohttp
from pydantic import BaseModel, Field

PLAN_HEADING = "## Research plan"
REPORT_HEADING = "## Deep research report"
FOOTER_MARK = "### ✅ Ready when you are"

APPROVE_RE = re.compile(
    r"^\s*(approve[ds]?|approval|go( ahead)?|run( it)?|start|yes|yep|ok(ay)?|do it|lgtm|looks good|proceed|execute)\b[\s,.:;!-]*",
    re.I,
)

# Words in the approval message that pick the main source: (pattern, LDR engine, label for people)
SOURCE_WORDS = [
    (re.compile(r"\b(pub ?med|medical|medicine|clinical|biomedical|health|journals?|peer[- ]reviewed)\b", re.I), "pubmed",
     "PubMed medical journals"),
    (re.compile(r"\b(arxiv|preprints?)\b", re.I), "arxiv", "arXiv science preprints"),
    (re.compile(r"\b(wikipedia|encyclop(a)?edia)\b", re.I), "wikipedia", "Wikipedia"),
    (re.compile(r"\b(web|searx(ng)?|general)\b", re.I), "searxng", "the web"),
]
ENGINE_LABEL = {"searxng": "the web", "pubmed": "PubMed medical journals", "arxiv": "arXiv science preprints", "wikipedia": "Wikipedia"}
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

FOOTER = f"""

---

{FOOTER_MARK}

**Reply with one of these** to start the research:

| 🔎 To research… | ✍️ Type |
|:--|:--|
| 🌐 **The whole web** — news, guides, official sites | `approve` |
| 🩺 **Medical journals** — peer-reviewed studies (PubMed) | `approve medical` |
| 🔬 **Science preprints** — the newest papers (arXiv) | `approve arxiv` |
| 📚 **Wikipedia** — quick, encyclopedia-level overview | `approve wikipedia` |
| ✏️ **Edit** — adjust the plan in your own words | `approve, add "XYZ"` |

⏱️ Research takes about **5 minutes**. You'll see each step tick off as it happens, then get the full report with sources."""


def clean_plan(text: str) -> str:
    """Drop leaked reasoning, keep only the last copy of the plan, remove the footer and any report."""
    text = text or ""
    text = re.sub(r"<details[^>]*>.*?</details>", "", text, flags=re.S)
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    text = text.split(REPORT_HEADING)[0]
    if PLAN_HEADING in text:
        text = PLAN_HEADING + text.rsplit(PLAN_HEADING, 1)[1]
    text = re.sub(r"\n-{3,}\s*\n+" + re.escape(FOOTER_MARK) + r".*$", "", text, flags=re.S)
    text = text.split(FOOTER_MARK)[0]
    text = re.sub(r"\n-{3,}\s*\n_(Reply \*\*approve\*\*|Edit anything above).*$", "", text, flags=re.S)
    return text.strip().rstrip("-").strip()


def text_of(content) -> str:
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def slug(text: str) -> str:
    text = re.sub(r"[^\w\s-]", "", text or "").strip()
    return re.sub(r"[\s_]+", "-", text)[:70].strip("-") or "deep-research"


class Pipe:
    class Valves(BaseModel):
        PLANNER_MODEL: str = Field(default="google/gemma-4-31B-it",
                                   description="Fallback plan writer (with the toggle, the model you chose writes the plan)")
        LDR_BASE_URL: str = Field(default="http://127.0.0.1:5000", description="Local Deep Research URL (Open WebUI runs on the host network)")
        LDR_USERNAME: str = Field(default="openwebui", description="LDR service account (DEEP_RESEARCH_USER in ~/HomeLab/.env)")
        LDR_PASSWORD: str = Field(default="", description="LDR service account password (DEEP_RESEARCH_PASSWORD in ~/HomeLab/.env)",
                                  json_schema_extra={"input": {"type": "password"}})
        RESEARCH_MODEL: str = Field(default="google/gemma-4-31B-it",
                                    description="W&B model LDR uses. Non-reasoning only: reasoning models return empty answers to LDR's short prompts")
        MODE: Literal["quick", "detailed"] = Field(default="quick", description="quick = cited summary (minutes); detailed = long multi-section report")
        ITERATIONS: int = Field(default=2, ge=1, le=8, description="Search rounds")
        QUESTIONS_PER_ITERATION: int = Field(default=3, ge=1, le=8, description="Follow-up questions per round")
        SEARCH_ENGINE: str = Field(default="searxng", description='Default LDR search engine ("approve medical" switches a run to pubmed)')
        ATTACH_FILES: bool = Field(default=True, description="Attach the report as PDF and Markdown downloads")
        POLL_SECONDS: int = Field(default=5, ge=2, le=60)
        TIMEOUT_MINUTES: int = Field(default=30, ge=5, le=180)
        ADMIN_ONLY: bool = Field(default=True, description="Only Open WebUI admins may use it (each run costs LLM tokens)")

    def __init__(self):
        self.valves = self.Valves()

    async def pipe(self, body: dict, __user__: dict | None = None, __request__=None, __event_emitter__=None,
                   __chat_id__: str | None = None, __message_id__: str | None = None, __task__=None):
        user = __user__ or {}
        planner = body.get("deep_research_planner_model") or self.valves.PLANNER_MODEL

        if __task__:  # Open WebUI background jobs
            if "follow_up" in str(__task__):  # no follow-up suggestions under plans or reports
                return '{"follow_ups": []}'
            return await self._complete(__request__, user, planner, body.get("messages") or [])  # title, tags

        if self.valves.ADMIN_ONLY and user.get("role") != "admin":
            return "Deep Research is limited to admins."

        # Open WebUI runs follow-up suggestions with the model recorded on the answer (the model the user
        # picked). Record this function instead, so that job comes back here and gets an empty list.
        await self._claim_message(__chat_id__, __message_id__)

        ui = UI(__event_emitter__, __chat_id__)
        msgs = [m for m in (body.get("messages") or []) if m.get("role") in ("user", "assistant")]
        last_user = text_of(msgs[-1].get("content")) if msgs and msgs[-1].get("role") == "user" else ""
        plan_msg = next((m for m in reversed(msgs[:-1]) if m.get("role") == "assistant" and PLAN_HEADING in text_of(m.get("content"))), None)

        m = APPROVE_RE.match(last_user)
        if plan_msg and m:
            notes = last_user[m.end():].strip()
            engine, label, rest = self.valves.SEARCH_ENGINE, "", notes
            for rx, eng, desc in SOURCE_WORDS:  # "approve medical" -> PubMed
                if rx.search(notes):
                    engine, label, rest = eng, desc, rx.sub("", notes)
                    break
            if FILLER_RE.fullmatch(rest):  # nothing but filler ("please do the research plan") -> no notes
                notes = ""
            plan = clean_plan(text_of(plan_msg.get("content")))
            if label:
                plan += f"\n\n**Primary source:** {label}. Base the findings on it and cite it."
            if notes:
                plan += f"\n\n**Additional instructions from the user:** {notes}"
            return await self._research(plan, ui, engine, user)
        return await self._plan(msgs, user, __request__, ui, planner)

    @staticmethod
    async def _claim_message(chat_id, message_id):
        if not chat_id or not message_id or str(chat_id).startswith("local:"):
            return
        try:
            from open_webui.models.chats import Chats
            await Chats.upsert_message_to_chat_by_id_and_message_id(chat_id, message_id, {"model": "deep_research"})
        except Exception:
            pass

    # ---------- model calls ----------
    async def _complete(self, request, user: dict, model: str, messages: list) -> str:
        from open_webui.models.users import Users
        from open_webui.utils.chat import generate_chat_completion
        user_obj = await Users.get_user_by_id(user["id"])
        res = await generate_chat_completion(request, {"model": model, "stream": False, "messages": messages}, user_obj, bypass_filter=True)
        if hasattr(res, "body"):  # JSONResponse
            import json
            res = json.loads(res.body)
        return ((res or {}).get("choices") or [{}])[0].get("message", {}).get("content") or ""

    # ---------- step 1: plan ----------
    async def _plan(self, msgs, user: dict, request, ui, planner: str) -> str:
        await ui.status(f"Writing the research plan ({planner.split('/')[-1]})…")
        convo = []
        for m in msgs:  # previous plans stay (so feedback revises them); reports are dropped
            content = text_of(m.get("content"))
            if m["role"] == "assistant":
                content = clean_plan(content) if PLAN_HEADING in content else content.split(REPORT_HEADING)[0].strip()
                if not content:
                    continue
            convo.append({"role": m["role"], "content": content})
        text = await self._complete(request, user, planner, [{"role": "system", "content": PLANNER_PROMPT}] + convo)
        plan = clean_plan(text)
        await ui.status("Plan ready — reply to approve or change it", True)
        if PLAN_HEADING not in plan:
            return text.strip() or "The planner returned nothing. Try again, or pick another model."
        return plan + FOOTER

    # ---------- step 2: research ----------
    async def _research(self, plan: str, ui, engine: str, user: dict) -> str:
        v = self.valves
        if not v.LDR_PASSWORD:
            return "Deep Research is not configured: set LDR_PASSWORD in the function's valves."
        label = ENGINE_LABEL.get(engine, engine)
        title = (re.search(r"\*\*Research question:\*\*\s*(.+)", plan) or [None, "Deep research report"])[1].strip()
        base = v.LDR_BASE_URL.rstrip("/")
        query = ("Carry out deep research following this approved research plan. Answer the research question, "
                 "use the sub-questions and search queries as guidance, respect the scope and source guidance, "
                 "and produce the requested deliverable with citations.\n\n" + plan)[:9500]
        steps = Steps(ui, label, v.ATTACH_FILES)
        await steps.start()
        t0 = time.time()
        rid, files = None, []
        try:
            # unsafe=True: aiohttp otherwise drops cookies set by an IP-address host (127.0.0.1)
            async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True),
                                             timeout=aiohttp.ClientTimeout(total=180)) as s:
                csrf = await self._login(s, base)
                async with s.post(f"{base}/api/start_research", headers={"X-CSRF-Token": csrf}, json={
                    "query": query, "mode": v.MODE, "model_provider": "openai_endpoint", "model": v.RESEARCH_MODEL,
                    "search_engine": engine, "search_engines": [engine],
                    "iterations": v.ITERATIONS, "questions_per_iteration": v.QUESTIONS_PER_ITERATION}) as r:
                    data = await r.json(content_type=None)
                rid = (data or {}).get("research_id")
                if not rid:
                    raise RuntimeError(f"LDR did not start the research: {str(data)[:200]}")
                st, last_log = {}, 0
                try:
                    while True:
                        await asyncio.sleep(v.POLL_SECONDS)
                        async with s.get(f"{base}/api/research/{rid}/status") as r:
                            st = await r.json(content_type=None) or {}
                        state, pct = st.get("status"), st.get("progress") or 0
                        last_log = await self._follow_logs(s, base, rid, last_log, steps)
                        if state in ("completed", "failed", "suspended", "error", "cancelled"):
                            break
                        if pct >= 90:
                            await steps.writing()
                        if time.time() - t0 > v.TIMEOUT_MINUTES * 60:
                            raise TimeoutError(f"timed out after {v.TIMEOUT_MINUTES} min")
                except (asyncio.CancelledError, TimeoutError):
                    # stop button in Open WebUI, or our timeout: stop the job in LDR too
                    async with s.post(f"{base}/api/terminate/{rid}", headers={"X-CSRF-Token": csrf}, json={}):
                        pass
                    raise
                if state != "completed":
                    raise RuntimeError(f"LDR research {state}: {str(st.get('error') or st.get('message') or '')[:300]}")
                await steps.writing()
                async with s.get(f"{base}/api/report/{rid}") as r:
                    rep = await r.json(content_type=None) or {}
                report = (rep.get("content") or rep.get("summary") or "").strip()
                if not report:
                    raise RuntimeError("LDR finished but returned an empty report")
                await steps.sources_used([x.get("url") for x in (rep.get("sources") or []) if isinstance(x, dict) and x.get("url")])
                if v.ATTACH_FILES:
                    await steps.files_started()
                    pdf = b""
                    try:
                        async with s.post(f"{base}/api/v1/research/{rid}/export/pdf", headers={"X-CSRF-Token": csrf}, json={}) as r:
                            if r.status == 200:
                                pdf = await r.read()
                    except Exception:
                        pdf = b""
                    files = await self._save_files(user, title, report, pdf)
                    await ui.files(files)
        except asyncio.CancelledError:
            await steps.cancel()
            raise
        except Exception as e:
            await steps.fail(str(e))
            return f"Deep research failed: {e}"
        mins, secs = divmod(int(time.time() - t0), 60)
        await steps.done(f"{mins}m{secs:02d}s")
        downloads = ""
        if files:
            links = " · ".join(f"[{'📄 PDF' if f['name'].endswith('.pdf') else '📝 Markdown'}](/api/v1/files/{f['id']}/content)" for f in files)
            downloads = f"\n\n**Download this report:** {links}"
        return f"{REPORT_HEADING}\n\n{report}{downloads}"

    async def _follow_logs(self, s, base: str, rid: str, last_id: int, steps) -> int:
        """Turn new LDR milestones into checklist progress and search-query chips."""
        try:
            async with s.get(f"{base}/api/research/{rid}/logs?limit=300") as r:
                logs = await r.json(content_type=None) or []
        except Exception:
            return last_id
        queries, topics, newest = [], [], last_id
        for row in logs if isinstance(logs, list) else []:
            try:
                lid = int(row.get("id") or 0)
            except ValueError:
                continue
            if lid <= last_id:
                continue
            newest = max(newest, lid)
            if str(row.get("log_type", "")).upper() != "MILESTONE":
                continue
            msg = str(row.get("message") or "")
            q = re.search(r"Searching[^:]*:\s*[\"“'](.+?)[\"”']\s*$", msg)
            if q:
                queries.append(q.group(1)[:90])
            t = re.search(r"Investigating subtopics?:\s*[\"“'](.+?)[\"”']?\s*$", msg)
            if t:  # LDR researches sub-questions in parallel: "q1…, q2…"
                topics += [x.strip(" .…\"'") for x in re.split(r"(?<=[?…]),\s+", t.group(1)) if x.strip(" .…\"'")]
            n = re.search(r"Synthesizing (\d+) sources", msg)
            g = re.search(r"(\d+) sources gathered", msg)
            if n:
                await steps.writing(int(n.group(1)))
            elif g:
                await steps.reading(int(g.group(1)))
            elif re.search(r"From the |From subtopic|Found \d+|results? for|fetch", msg, re.I):
                await steps.reading()
        if queries or topics:
            await steps.searched(queries, topics)
        return newest

    async def _save_files(self, user: dict, title: str, report: str, pdf: bytes) -> list:
        """Store the report in Open WebUI's file storage so it can be downloaded from the chat."""
        from open_webui.models.files import FileForm, Files
        from open_webui.storage.provider import Storage
        out, name = [], slug(title)
        for data, ext, ctype in [(pdf, "pdf", "application/pdf"), (f"# {title}\n\n{report}\n".encode(), "md", "text/markdown")]:
            if not data:
                continue
            fid, fname = str(uuid.uuid4()), f"{name}.{ext}"
            _, path = Storage.upload_file(io.BytesIO(data), f"{fid}_{fname}",
                                          {"OpenWebUI-User-Email": user.get("email", ""), "OpenWebUI-User-Id": user["id"],
                                           "OpenWebUI-User-Name": user.get("name", ""), "OpenWebUI-File-Id": fid})
            await Files.insert_new_file(user["id"], FileForm(id=fid, filename=fname, path=path,
                                                             meta={"name": fname, "content_type": ctype, "size": len(data), "source": "deep_research"}))
            out.append({"type": "file", "id": fid, "name": fname, "url": f"/api/v1/files/{fid}", "size": len(data),
                        "content_type": ctype, "status": "uploaded"})
        return out

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


class UI:
    """Open WebUI events: status lines, the task checklist, file attachments."""

    def __init__(self, emitter, chat_id):
        self.emit, self.chat_id = emitter, chat_id

    async def status(self, description: str, done: bool = False, **extra):
        if self.emit:
            await self.emit({"type": "status", "data": {"description": description, "done": done, **extra}})

    async def tasks(self, tasks: list):
        if self.chat_id and not str(self.chat_id).startswith("local:"):
            try:
                from open_webui.models.chats import Chats
                await Chats.update_chat_tasks_by_id(self.chat_id, tasks)
            except Exception:
                pass
        if self.emit:
            await self.emit({"type": "chat:message:tasks", "data": {"tasks": tasks}})

    async def files(self, files: list):
        if self.emit and files:
            await self.emit({"type": "files", "data": {"files": files}})


class Steps:
    """The research checklist shown in the chat, moved forward by LDR's progress."""

    def __init__(self, ui: UI, label: str, with_files: bool):
        self.ui, self.label, self.with_files = ui, label, with_files
        self.searches, self.topics, self.sources = 0, 0, 0
        self.items = [
            {"id": "plan", "content": "Read the approved plan and pick search strategies", "status": "pending"},
            {"id": "search", "content": f"Search {label}", "status": "pending"},
            {"id": "read", "content": "Read and compare the sources", "status": "pending"},
            {"id": "write", "content": "Write the report with citations", "status": "pending"},
        ]
        if with_files:
            self.items.append({"id": "files", "content": "Prepare PDF and Markdown downloads", "status": "pending"})
        self.t0 = time.time()

    def _set(self, sid: str, status: str, content: str | None = None):
        for t in self.items:
            if t["id"] == sid:
                if t["status"] != "completed" or status in ("completed", "cancelled"):
                    t["status"] = status
                if content:
                    t["content"] = content

    def _complete_before(self, sid: str):
        for t in self.items:
            if t["id"] == sid:
                break
            if t["status"] != "completed":
                t["status"] = "completed"

    async def _push(self):
        await self.ui.tasks([dict(t) for t in self.items])

    def _elapsed(self) -> str:
        e = int(time.time() - self.t0)
        return f"{e // 60}m{e % 60:02d}s"

    async def start(self):
        self._set("plan", "in_progress")
        await self._push()
        await self.ui.status(f"Starting deep research on {self.label}…")

    def _search_text(self, final: bool = False) -> str:
        parts = []
        if self.topics:
            parts.append(f"{self.topics} question{'s' if self.topics != 1 else ''}")
        if self.searches:
            parts.append(f"{self.searches} search{'es' if self.searches != 1 else ''}")
        return f"Search {self.label}" + (f" · {' · '.join(parts)}" if parts else "") + ("" if final or not parts else " so far")

    async def searched(self, queries: list, topics: list | None = None):
        topics = topics or []
        self.searches += len(queries)
        self.topics += len(topics)
        self._complete_before("search")
        self._set("search", "in_progress", self._search_text())
        await self._push()
        chips = (topics + queries)[:8]
        what = "Investigating" if topics and not queries else "Searching"
        await self.ui.status(f"{what} {self.label}", action="web_search_queries_generated", queries=chips)

    async def reading(self, sources: int | None = None):
        changed = False
        if sources and sources != self.sources:
            self.sources = sources
            self._set("read", self._status("read") if self._status("read") != "pending" else "in_progress",
                      f"Read and compare the sources · {sources} found")
            changed = True
        if self._status("read") == "pending":
            self._set("read", "in_progress")
            changed = True
        if changed:
            await self._push()

    async def writing(self, sources: int | None = None):
        if sources:
            self.sources = sources
        if self._status("write") in ("in_progress", "completed") and not sources:
            return
        self._complete_before("write")
        self._set("search", "completed", self._search_text(final=True))
        if self.sources:
            self._set("read", "completed", f"Read and compare the sources · {self.sources} sources")
        self._set("write", "in_progress")
        await self._push()
        await self.ui.status(f"Writing the report{f' from {self.sources} sources' if self.sources else ''}… ({self._elapsed()})")

    async def sources_used(self, urls: list):
        if urls:
            await self.ui.status(f"Used {len(urls)} sources", done=True, action="web_search", urls=urls[:60])

    async def files_started(self):
        self._complete_before("files")
        self._set("files", "in_progress")
        await self._push()

    async def done(self, took: str):
        for t in self.items:
            t["status"] = "completed"
        await self._push()
        await self.ui.status(f"Deep research complete · {took}", True)

    async def fail(self, error: str):
        for t in self.items:
            if t["status"] == "in_progress":
                t["status"] = "cancelled"
        await self._push()
        await self.ui.status(f"Deep research failed: {error[:200]}", True)

    async def cancel(self):
        for t in self.items:
            if t["status"] in ("pending", "in_progress"):
                t["status"] = "cancelled"
        await self._push()

    def _status(self, sid: str) -> str:
        return next((t["status"] for t in self.items if t["id"] == sid), "")
