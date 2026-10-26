#!/usr/bin/env bash
# Find the board definition files in the community OpenWrt build repo
# (they contain the eMMC dd offsets / install recipe).
mkdir -p ~/bpi-r4-probe && cd ~/bpi-r4-probe || exit 1
UA='bpi-image-probe'
for br in master main; do
  curl -s --max-time 20 -H "User-Agent: $UA" "https://api.github.com/repos/IncubusRK/openwrt-bpi-r4/git/trees/$br?recursive=1" -o tree_$br.json
  if grep -q '"path"' tree_$br.json 2>/dev/null; then
    echo "branch: $br"
    grep -oE '"path": "[^"]*"' tree_$br.json | sed 's/"path": //' | grep -iE 'bpi|emmc|install|image|make|flash|dts' | head -40
    break
  fi
done
echo find-recipe-done
