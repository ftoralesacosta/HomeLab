#!/usr/bin/env bash
# Probe 5: official OpenWrt mediatek/filogic + IncubusRK release assets.
mkdir -p ~/bpi-r4-probe && cd ~/bpi-r4-probe || exit 1
UA='bpi-image-probe'

echo '=== 1. OFFICIAL OPENWRT: mediatek/filogic bpi-r4 ==='
for v in 25.12.6 24.10.8 24.10.7 23.05.5; do
  echo "-- $v"
  curl -s --max-time 25 "https://downloads.openwrt.org/releases/$v/targets/mediatek/filogic/" | grep -oiE '[^"<>]*bpi-r4[^"<>]*' | sort -u | head -15
done

echo '=== 2. IncubusRK/openwrt-bpi-r4 releases ==='
curl -s --max-time 20 -H "User-Agent: $UA" 'https://api.github.com/repos/IncubusRK/openwrt-bpi-r4/releases?per_page=15' -o incubus_rel.json
python3 - <<'PY'
import json
d = json.load(open('incubus_rel.json'))
if isinstance(d, dict):
    print('  API message:', d.get('message')); raise SystemExit
print(f"  {len(d)} releases")
for rel in d[:10]:
    print(f"  release {rel['tag_name']}  {str(rel.get('published_at',''))[:10]}")
    for a in rel.get('assets', []):
        if 'bpi-r4' in a['name']:
            print(f"    {a['name']}  {a['size']}")
            print(f"      {a['browser_download_url']}")
PY
echo probe5-done
