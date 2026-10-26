#!/usr/bin/env bash
# Probe 3: sitemaps, GitHub search, OpenWrt forum, doc portal.
mkdir -p ~/bpi-r4-probe && cd ~/bpi-r4-probe || exit 1
UA='Mozilla/5.0 (X11; Linux x86_64) bpi-image-probe'

echo '=== 1. GitHub repo search (bpi-r4) ==='
curl -s --max-time 20 -H "User-Agent: $UA" 'https://api.github.com/search/repositories?q=bpi-r4&per_page=20' -o gh_search.json
grep -oE '"full_name": "[^"]*"' gh_search.json | sed 's/"full_name": //' | head -20

echo '=== 2. bananapi.org sitemap ==='
for sm in 'https://www.bananapi.org/sitemap.xml' 'https://www.bananapi.org/wp-sitemap.xml' 'https://www.bananapi.org/sitemap_index.xml'; do
  echo "-- $sm"
  curl -sL --max-time 20 -A "$UA" "$sm" -o sm.xml -w 'http=%{http_code} bytes=%{size_download}\n'
  grep -oE '<loc>[^<]*</loc>' sm.xml | sed 's/<\/*loc>//g' | grep -iE 'r4|download|firmware|image' | head -20
done

echo '=== 3. open.bpi-arm.com sitemaps/paths ==='
for u in 'https://open.bpi-arm.com/sitemap.xml' 'https://open.bpi-arm.com/robots.txt'; do
  echo "-- $u"
  curl -sL --max-time 20 -A "$UA" "$u" -o bpiarm.txt -w 'http=%{http_code} bytes=%{size_download}\n'
  head -c 400 bpiarm.txt; echo
done

echo '=== 4. OpenWrt forum search (Discourse JSON) ==='
curl -s --max-time 20 -A "$UA" 'https://forums.openwrt.org/search.json?q=bpi-r4' -o forum_search.json
grep -oE '"(title|id|slug)": ?[^,]*' forum_search.json | head -30

echo '=== 5. wiki.bananapi.org alive? ==='
curl -sI --max-time 15 -A "$UA" 'https://wiki.bananapi.org/' 2>&1 | head -5

echo '=== 6. wayback availability: open.bpi-arm.com + r4 download guesses ==='
for u in 'open.bpi-arm.com' 'www.bananapi.org/bananapi-r4/download/' 'wiki.bananapi.org/wiki/index.php?title=BPI-R4'; do
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$u")
  echo "-- $u"
  curl -s --max-time 15 "https://archive.org/wayback/available?url=$enc" ; echo
done
echo probe3-done
