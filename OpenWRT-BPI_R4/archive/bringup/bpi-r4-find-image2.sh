#!/usr/bin/env bash
# Hunt for Banana Pi's own BPI-R4 OpenWrt image. Saves raw data to ~/bpi-r4-probe/
mkdir -p ~/bpi-r4-probe && cd ~/bpi-r4-probe || exit 1

echo '=== 1. GitHub org "bananapi" repos ==='
curl -s --max-time 20 'https://api.github.com/orgs/bananapi/repos?per_page=100' -o gh_repos.json
grep -oE '"full_name": "[^"]*"' gh_repos.json | sed 's/"full_name": //' | head -40

echo '=== 2. GitHub releases for likely repos ==='
for r in bpi-r4 BPI-R4 bpi-r4-firmware bpi-r4-image; do
  echo "-- repo: bananapi/$r"
  curl -s --max-time 20 "https://api.github.com/repos/bananapi/$r/releases?per_page=5" -o "gh_rel_$r.json"
  grep -oE '"(tag_name|browser_download_url)": "[^"]*"' "gh_rel_$r.json" | head -12
done

echo '=== 3. candidate download hosts ==='
for h in 'https://download.bananapi.org/' 'https://nbd.bpi-arm.com/' 'https://firmware.bananapi.org/'; do
  tag=$(echo "$h" | md5sum | cut -c1-6)
  code=$(curl -s --max-time 15 -o "host_$tag.html" -w '%{http_code}' "$h" 2>/dev/null)
  echo "$h -> $code ($(wc -c < host_$tag.html 2>/dev/null) bytes)"
done

echo '=== 4. product page firmware links ==='
curl -sL --max-time 25 'https://www.bananapi.org/bananapi-r4/' -o product.html
echo "product.html: $(wc -c < product.html) bytes"
grep -oiE 'href="[^"]*"' product.html | sort -u | grep -iE 'firmware|download|openwrt|\.img|image' | head -30

echo '=== 5. wayback of old wiki BPI-R4 page ==='
curl -s --max-time 20 'https://archive.org/wayback/available?url=wiki.bananapi.org/wiki/index.php%3Ftitle%3DBPI-R4' -o wb.json
cat wb.json; echo
snap=$(grep -oE '"url": "https://web.archive.org/[^"]*"' wb.json | head -1 | sed 's/"url": "//;s/"//')
if [ -n "$snap" ]; then
  echo "snapshot: $snap"
  curl -sL --max-time 30 "$snap" -o wb_wiki.html
  python3 - <<'PY'
import re, html
t = open('wb_wiki.html', encoding='utf-8', errors='ignore').read()
t = re.sub(r'<(script|style)[^>]*>.*?</\1>', '', t, flags=re.S)
links = re.findall(r'href="([^"]+)"', t)
links = [l for l in links if re.search(r'(?i)(openwrt|firmware|\.img|download|image|drive)', l)]
print('--- interesting links ---')
for l in dict.fromkeys(links): print(l)
t2 = re.sub(r'<[^>]+>', ' ', t)
t2 = html.unescape(re.sub(r'\s+', ' ', t2))
i = t2.lower().find('openwrt')
print('--- context around first "openwrt" ---')
print(t2[max(0,i-300):i+600] if i >= 0 else '(no openwrt mention found)')
PY
fi
echo probe-done
