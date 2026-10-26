import json, time, urllib.request, urllib.parse, re, html, sys, os
OUT = os.path.expanduser("~/bpi-r4-onu/research"); os.makedirs(OUT, exist_ok=True)
UA = {"User-Agent": "Mozilla/5.0 (research)"}
def get(url, tries=3):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=25) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:
            err = e; time.sleep(5)
    return json.dumps({"error": str(err)})
def clean(s): return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s or "")))
log = open(os.path.join(OUT, "search.txt"), "w")
def P(*a):
    print(*a); print(*a, file=log); log.flush()

# GitHub issue search (unauthenticated: 10 req/min)
gh = [
 'repo:Anime4000/RTL960x autoneg', 'repo:Anime4000/RTL960x SGMII', 'repo:Anime4000/RTL960x "link down"',
 'repo:Anime4000/RTL960x flapping', 'repo:Anime4000/RTL960x mediatek', 'repo:Anime4000/RTL960x BPI',
 'repo:Anime4000/RTL960x LAN_SDS_MODE', 'repo:Anime4000/RTL960x openwrt', 'repo:Anime4000/RTL960x "1000base-x"',
 '"XPON-Stick" sfp quirk', '"DFP-34X" openwrt sfp', 'sfp quirk gpon "autoneg" mediatek',
]
for q in gh:
    d = get("https://api.github.com/search/issues?per_page=15&q=" + urllib.parse.quote(q))
    try: items = json.loads(d).get("items", [])
    except Exception: items = []
    P("\n######## GH:", q, len(items))
    for it in items:
        P(" -", it["html_url"], "|", it["title"][:90], "| comments", it.get("comments"))
    time.sleep(7)

# Banana Pi forum
for q in ["XPON-Stick", "LL-XS2510", "DFP-34X", "gpon stick autoneg", "sfp autoneg off 1000base-x", "gpon link flapping", "sfp in-band-status", "RTL9601"]:
    d = get("https://forum.banana-pi.org/search.json?q=" + urllib.parse.quote(q))
    try: j = json.loads(d)
    except Exception: j = {}
    t = {x["id"]: x["title"] for x in j.get("topics", [])}
    P("\n######## BPI:", q)
    for p in j.get("posts", [])[:10]:
        P(" -", p["topic_id"], "#%s" % p.get("post_number"), "|", t.get(p["topic_id"], "")[:60], "|", clean(p.get("blurb"))[:220])
    time.sleep(3)

# OpenWrt forum (rate limited -> slow)
for q in ["XPON-Stick", "LL-XS2510", "DFP-34X-2C2", "ODI gpon sfp autoneg", "gpon sfp 1000base-x autoneg off", "RTL9601D", "sfp-lan autoneg"]:
    d = get("https://forum.openwrt.org/search.json?q=" + urllib.parse.quote(q))
    try: j = json.loads(d)
    except Exception: j = {}
    t = {x["id"]: x["title"] for x in j.get("topics", [])}
    P("\n######## OWRT:", q, "" if j.get("posts") is not None else d[:120])
    for p in j.get("posts", [])[:10]:
        P(" -", p["topic_id"], "#%s" % p.get("post_number"), "|", t.get(p["topic_id"], "")[:60], "|", clean(p.get("blurb"))[:220])
    time.sleep(15)
P("\nDONE")
