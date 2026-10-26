import re, sys, urllib.parse
html = open(sys.argv[1], encoding="latin-1").read()
def form_fields(name):
    m = re.search(r'<form[^>]*name="%s"[^>]*>(.*?)</form>' % name, html, re.S | re.I)
    body = m.group(1)
    fields = []
    for inp in re.finditer(r"<input([^>]*)>", body, re.I):
        a = inp.group(1)
        n = re.search(r'name="([^"]+)"', a); v = re.search(r'value="([^"]*)"', a)
        t = re.search(r'type="([^"]+)"', a)
        if not n: continue
        t = (t.group(1).lower() if t else "text")
        if t == "radio" and "checked" not in a: continue
        if t == "submit": continue
        fields.append([n.group(1), v.group(1) if v else ""])
    for sel in re.finditer(r'<select[^>]*name="?([^" >]+)"?[^>]*>(.*?)</select>', body, re.S | re.I):
        opts = re.findall(r'<option([^>]*)value="?([^" >]+)"?', sel.group(2), re.I)
        chosen = [v for a, v in opts if "selected" in a] or [opts[0][1]]
        fields.append([sel.group(1), chosen[0]])
    return fields
omci = form_fields("formOmciInfo")
for f in omci:
    if f[0] == "fiberreset": f[1] = "0"
if not any(f[0] == "fiberreset" for f in omci): omci.append(["fiberreset", "0"])
omci.append(["apply", "Apply Changes"])
gpon = form_fields("formgponconf")
for f in gpon:
    if f[0] == "fmgpon_ploam_password": f[1] = ""
    if f[0] == "fmgpon_ploamformat": f[1] = "1"   # ASCII (matches GPON_PLOAM_FORMAT=1)
if not any(f[0] == "fmgpon_ploamformat" for f in gpon): gpon.append(["fmgpon_ploamformat", "1"])
gpon.append(["apply", "Apply Changes"])
print("OMCI=" + urllib.parse.urlencode([tuple(x) for x in omci]))
print("GPON=" + urllib.parse.urlencode([tuple(x) for x in gpon]))
