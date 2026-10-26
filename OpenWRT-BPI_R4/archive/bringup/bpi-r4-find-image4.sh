#!/usr/bin/env bash
# Probe 4: official BPI org repos + releases/assets of candidate build repos.
mkdir -p ~/bpi-r4-probe && cd ~/bpi-r4-probe || exit 1
UA='bpi-image-probe'

echo '=== 1. all BPI-SINOVOIP org repos ==='
curl -s --max-time 20 -H "User-Agent: $UA" 'https://api.github.com/orgs/BPI-SINOVOIP/repos?per_page=100' -o bpi_org_repos.json
grep -oE '"full_name": "[^"]*"' bpi_org_repos.json | sed 's/"full_name": //' | head -60

echo '=== 2. releases + assets of candidate repos ==='
for r in BPI-SINOVOIP/BPI-R4-OPENWRT-V21.02 BPI-SINOVOIP/BPI-R4-bsp-6.1 IncubusRK/openwrt-bpi-r4 Shuery-Shuai/ImmortalWrt-BPI-R4-Firmware woziwrt/bpi-r4-deploy MedyMa/BananaPi-BPI-R4; do
  echo "----- $r"
  curl -s --max-time 20 -H "User-Agent: $UA" "https://api.github.com/repos/$r/releases?per_page=8" -o rel.json
  python3 - <<'PY'
import json
try: d=json.load(open('rel.json'))
except Exception as e: print('  parse fail', e); raise SystemExit
if isinstance(d,dict):
    print('  ', d.get('message','?')); raise SystemExit
if not d: print('  (no releases)')
for rel in d[:8]:
    print(f"  release {rel['tag_name']}  {str(rel.get('published_at',''))[:10]}  name={rel.get('name','')[:50]}")
    for a in rel.get('assets',[]):
        print(f"    {a['name']}  ({a['size']})  {a['browser_download_url']}")
PY
done

echo '=== 3. README download links ==='
for r in BPI-SINOVOIP/BPI-R4-OPENWRT-V21.02 IncubusRK/openwrt-bpi-r4 Shuery-Shuai/ImmortalWrt-BPI-R4-Firmware; do
  n=$(echo "$r" | tr '/' '_')
  echo "----- $r"
  curl -s --max-time 20 -H "User-Agent: $UA" -H 'Accept: application/vnd.github.raw' "https://api.github.com/repos/$r/readme" -o "readme_$n.md"
  grep -oiE 'https?://[^ )>"`]+' "readme_$n.md" | grep -iE 'img|image|firmware|download|release|openwrt' | sort -u | head -15
done

echo '=== 4. docs.bananapi.cn sitemap ==='
curl -sL --max-time 20 -A "$UA" 'https://docs.bananapi.cn/sitemap.xml' -o docs_sm.xml -w 'http=%{http_code} bytes=%{size_download}\n'
grep -oE '<loc>[^<]*</loc>' docs_sm.xml 2>/dev/null | sed 's/<\/*loc>//g' | grep -iE 'r4' | head -15

echo probe4-done
