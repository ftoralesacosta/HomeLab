#!/usr/bin/env bash
# Run once you're back at the BPI-R4:  bash ~/bpi-r4-back-at-desk.sh
set -u
IF=enx000ec67d6484
IMG_DIR=~/bpi-r4-images
mkdir -p "$IMG_DIR"

echo '=== 0. DEPS (tcpdump, picocom) ==='
sudo apt-get install -y tcpdump picocom >/dev/null && echo deps ok

echo '=== 1. SNIFF 60s (any traffic = board OS alive) ==='
sudo timeout 60 tcpdump -i "$IF" -e -n -c 100 2>&1 | head -80

echo '=== 2. SUBNET SWEEP ==='
for base in 192.168.0 192.168.100 192.168.11 192.168.5 10.0.0 172.16.0; do
  sudo ip addr flush dev "$IF" 2>/dev/null
  sudo ip addr add ${base}.100/24 dev "$IF"
  sleep 1
  ping -c1 -W2 ${base}.1 >/dev/null 2>&1 && echo "ALIVE: ${base}.1"
done
sudo ip addr flush dev "$IF" 2>/dev/null; sudo ip addr add 192.168.1.100/24 dev "$IF"

echo '=== 3. OPENWRT IMAGE (25.12.6, fallback 24.10.8) ==='
found=0
for v in 25.12.6 24.10.8; do
  f=$(curl -s "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/" \
      | grep -oE '>[^<]*bpi-r4[^<]*\.img\.gz' | sed 's/^>//' | sort -u | head -1)
  if [ -n "${f:-}" ]; then
    found=1
    echo "Found in $v: $f"
    curl -sS --retry 3 -o "$IMG_DIR/$f" "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/$f" \
      && echo "saved: $IMG_DIR/$f"
    curl -sS -o "$IMG_DIR/$f.sha256sum" "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/$f.sha256sum" \
      && ( cd "$IMG_DIR" && sha256sum -c "$f.sha256sum" )
    break
  fi
  echo "no bpi-r4 image in $v"
done
[ "$found" = 1 ] || echo 'WARNING: no bpi-r4 image found in either release'

echo '=== 4. SERIAL CONSOLE ==='
ls -l /dev/ttyUSB* 2>/dev/null || echo 'no /dev/ttyUSB* yet - plug in the CH340G module'
echo 'When the CH340G is connected:  sudo picocom -b 115200 /dev/ttyUSB0   (exit: Ctrl-A then X)'
