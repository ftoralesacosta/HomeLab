import json, urllib.request, re, sys
UA = {"User-Agent": "Mozilla/5.0"}
def get(u):
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=30) as r: return r.read().decode("utf-8", "replace")
    except Exception as e: return "ERR %s" % e
br = sys.argv[1] if len(sys.argv) > 1 else "openwrt-25.12"
# 1) kernel config: is SFP built-in or a module on filogic?
for path in ["target/linux/mediatek/filogic/config-6.12", "target/linux/generic/config-6.12", "target/linux/mediatek/config-6.12"]:
    t = get("https://raw.githubusercontent.com/openwrt/openwrt/%s/%s" % (br, path))
    m = [l for l in t.splitlines() if re.search(r"CONFIG_SFP\b|CONFIG_SFP=|# CONFIG_SFP is", l)]
    print(path, "->", m if m else ("(not found)" if not t.startswith("ERR") else t[:80]))
# kmod-sfp package definition
t = get("https://raw.githubusercontent.com/openwrt/openwrt/%s/package/kernel/linux/modules/netdevices.mk" % br)
i = t.find("define KernelPackage/sfp")
print("kmod-sfp def:", t[i:i+400] if i >= 0 else "not found")
# 2) any patch touching sfp quirks
tree = json.loads(get("https://api.github.com/repos/openwrt/openwrt/git/trees/%s?recursive=1" % br))
paths = [x["path"] for x in tree.get("tree", []) if x["path"].startswith("target/linux/") and "6.12" in x["path"] and x["type"] == "blob"]
cand = [p for p in paths if re.search(r"sfp", p, re.I)]
print("sfp-related patches:", len(cand))
for p in cand:
    t = get("https://raw.githubusercontent.com/openwrt/openwrt/%s/%s" % (br, p))
    hit = re.findall(r'SFP_QUIRK[^\n]*', t)
    flag = [h for h in hit if re.search(r"XPON|OEM|ODI|DFP|HSGQ|ignore_los|disable_autoneg", h)]
    print(" -", p, "| quirks:", len(hit), "| relevant:", flag[:6])
