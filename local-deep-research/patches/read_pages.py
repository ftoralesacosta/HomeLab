"""Make LDR's research read full pages instead of answering from search snippets alone.

Why: with the langgraph-agent strategy, opening a page is left to the model (fetch_content tool),
and Gemma 4 never calls it, even when the prompt tells it to. So this patch makes every web search
done by the research sub-agents also read the top result pages (LDR's own fetch_content tool, in
its "summary_focus_query" mode: it downloads the page and keeps only the passages relevant to the
search) and appends those excerpts to the search results. Fetches still count against
search.fetch.max_per_topic, and read pages are cited like any other source.

Applied at container start (entrypoint in docker-compose.yml). Written for local-deep-research
2.0.1: each edit is skipped with a warning if its target text is gone (e.g. after an upgrade), so
LDR always starts; re-check this file when upgrading. Idempotent: safe to run on every start.
"""
import importlib.util
import sys

MOD = "local_deep_research.advanced_search_system.strategies.langgraph_agent_strategy"
PAGES_PER_SEARCH = 2

AUTO_READ = f'''        if sub_fetch is not None:
            sub_tools.append(sub_fetch)
        # [homelab read_pages patch] every sub-agent web search also reads the top result pages.
        if sub_fetch is not None and sub_tools and sub_tools[0].name == "web_search":
            _hl_search, _hl_fetch = sub_tools[0], sub_fetch
            _hl_url = re.compile(r"^\\[\\d+\\] .* \\((https?://\\S+)\\)$", re.M)

            @tool("web_search", description=_hl_search.description)
            def _hl_web_search(query: str) -> str:
                """Search the web; the top result pages are also read in full."""
                out = _hl_search.invoke({{"query": query}})
                if not isinstance(out, str):
                    return out
                urls = list(dict.fromkeys(_hl_url.findall(out)))
                read = []
                for u in urls:
                    if len(read) >= {PAGES_PER_SEARCH}:
                        break
                    try:
                        page = _hl_fetch.invoke({{"url": u, "focus": query}})
                    except Exception as exc:  # never break the search itself
                        logger.warning("read_pages: fetch failed for {{}}: {{}}", u, type(exc).__name__)
                        continue
                    if isinstance(page, str) and page.strip():
                        if page.startswith("Fetch content budget exhausted"):
                            break  # per-topic fetch budget used up
                        read.append(page)
                logger.info("read_pages: web_search read {{}} page(s)", len(read))
                if read:
                    out += "\\n\\n=== Full-page excerpts from the top results ===\\n\\n" + "\\n\\n".join(read)
                return out

            sub_tools[0] = _hl_web_search
'''

EDITS = [
    (
        "        if sub_fetch is not None:\n            sub_tools.append(sub_fetch)\n",
        AUTO_READ,
    ),
    (
        '"Search thoroughly and return a concise factual summary. "',
        '"Search thoroughly and return a concise factual summary. Each web_search also reads '
        'the top result pages: prefer the facts in those full-page excerpts over snippets. "',
    ),
]

spec = importlib.util.find_spec(MOD)
if spec is None or not spec.origin:
    print(f"[read_pages] {MOD} not found; nothing patched", file=sys.stderr)
    sys.exit(0)
path = spec.origin
src = open(path, encoding="utf-8").read()
if "[homelab read_pages patch]" in src:
    print("[read_pages] already applied")
    sys.exit(0)
new_src = src
for old, new in EDITS:
    if new_src.count(old) != 1:
        print(f"[read_pages] WARNING: target not found once, patch NOT applied: {old[:60]!r}", file=sys.stderr)
        sys.exit(0)
    new_src = new_src.replace(old, new, 1)
try:
    compile(new_src, path, "exec")
except SyntaxError as exc:
    print(f"[read_pages] WARNING: patched file does not compile ({exc}); NOT applied", file=sys.stderr)
    sys.exit(0)
open(path, "w", encoding="utf-8").write(new_src)
print(f"[read_pages] applied to {path}")
