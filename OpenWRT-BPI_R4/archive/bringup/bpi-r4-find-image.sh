#!/usr/bin/env bash
# Probe where the BPI-R4 OpenWrt image actually lives.
# Usage: bash ~/bpi-r4-find-image.sh
echo '=== 1. RAW INDEX 25.12.6 ==='
curl -s -o /tmp/a.html -w 'http=%{http_code} bytes=%{size_download}\n' https://downloads.openwrt.org/releases/25.12.6/targets/rockchip/armv8/
head -c 500 /tmp/a.html; echo
echo '--- bpi/bananapi mentions ---'
grep -oiE '[^"<>]*bpi[^"<>]*' /tmp/a.html | sort -u | head -20
echo '--- sample .img.gz entries ---'
grep -oE '>[^<]*\.img\.gz' /tmp/a.html | sed 's/^>//' | head -25
echo '=== 2. SCAN ALL OPENWRT RELEASES FOR bpi-r4 ==='
for v in $(curl -s https://downloads.openwrt.org/releases/ | grep -oE 'title="[0-9.]+"' | sed 's/title="//;s/"//' | sort -uV); do
  hit=$(curl -s --max-time 20 "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/" | grep -oiE '[^"<>]*bpi-r4[^"<>]*' | sort -u | head -4)
  [ -n "$hit" ] && { echo "== $v =="; echo "$hit"; }
done
echo scan-done
echo '=== 3. BANANA PI DOCS LINKS ==='
for u in 'https://wiki.bananapi.org/wiki/index.php?title=BPI-R4' 'https://open.bpi-arm.com/'; do
  echo "-- $u"
  curl -sL --max-time 20 "$u" 2>/dev/null | grep -oiE 'href="[^"]*(openwrt|firmware|\.img|download)[^"]*"' | sort -u | head -25
done
echo all-done
