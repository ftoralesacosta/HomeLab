#!/usr/bin/env bash
# ldr.sh <terminate|test MODEL [QUERY]> : service-account helper (creds from .env, never printed)
set -euo pipefail
cd ~/HomeLab
eval "$(grep -E '^DEEP_RESEARCH_(USER|PASSWORD)=' .env | sed 's/^/export /')"
ACTION="$1" MODEL="${2:-}" QUERY="${3:-What are the main differences between the James Webb and Hubble space telescopes, and what has JWST discovered so far?}" \
python3 -u - <<'EOF'
import http.cookiejar, json, os, re, time, urllib.parse, urllib.request
B = "http://127.0.0.1:5000"
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
def req(method, p, data=None, form=False, headers=None):
    body = None; h = dict(headers or {})
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
    r = op.open(urllib.request.Request(B + p, data=body, headers=h, method=method), timeout=120)
    return r.geturl(), r.read().decode()
csrf = re.search(r'name="csrf_token"[^>]*value="([^"]*)"', req("GET", "/auth/login")[1]).group(1)
url, _ = req("POST", "/auth/login", {"username": os.environ["DEEP_RESEARCH_USER"], "password": os.environ["DEEP_RESEARCH_PASSWORD"], "remember": "false", "csrf_token": csrf}, form=True)
assert "/auth/login" not in url, "login failed"
H = {"X-CSRF-Token": json.loads(req("GET", "/auth/csrf-token")[1])["csrf_token"]}
A = os.environ["ACTION"]
if A == "terminate":
    hist = json.loads(req("GET", "/history/api")[1])
    items = hist.get("items", hist) if isinstance(hist, dict) else hist
    for it in items[:10]:
        st = it.get("status")
        print("history:", it.get("id"), st, str(it.get("query"))[:50])
        if st in ("in_progress", "queued", "pending", "running"):
            print("  terminate ->", req("POST", f"/api/terminate/{it['id']}", {}, headers=H)[1][:120])
elif A == "test":
    req("PUT", "/settings/api/llm.model", {"value": os.environ["MODEL"]}, headers=H); print("model:", os.environ["MODEL"])
    t0 = time.time()
    rid = json.loads(req("POST", "/api/start_research", {"query": os.environ["QUERY"], "mode": "quick", "search_engines": ["searxng"],
                                                          "iterations": 2, "questions_per_iteration": 3}, headers=H)[1])["research_id"]
    print("research id:", rid); last = None
    while True:
        time.sleep(8)
        st = json.loads(req("GET", f"/api/research/{rid}/status")[1])
        line = f"{st.get('status')}  {st.get('progress')}%  {str(st.get('message') or '')[:100]}"
        if line != last: print(f"{int(time.time()-t0):4d}s  {line}"); last = line
        if st.get("status") in ("completed", "failed", "suspended", "error", "cancelled"): break
        if time.time() - t0 > 1500: print("timeout"); req("POST", f"/api/terminate/{rid}", {}, headers=H); break
    d = json.loads(req("GET", f"/api/report/{rid}")[1])
    content = d.get("content") or d.get("report") or d.get("summary") or ""
    open("/tmp/ldr_test_report.md", "w").write(content)
    print(f"DONE in {int(time.time()-t0)}s | report {len(content)} chars | keys {list(d)[:10]}")
    print("distinct links:", len(set(re.findall(r'https?://[^\s)\]>]+', content))))
EOF
