#!/usr/bin/env bash
# Flash the OpenWrt BPI-R4 image to the USB SD card reader on this server.
# Usage: bash ~/bpi-r4-flash-sd.sh
set -u
IMG_DIR="$HOME/bpi-r4-images"
mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo '=== 1. locate SD card (expect ~7-8 GiB "STORAGE DEVICE") ==='
TARGET=""
for d in /sys/block/sd*; do
  n=$(basename "$d")
  sectors=$(cat "$d/size" 2>/dev/null || echo 0)
  gib=$(( sectors * 512 / 1073741824 ))
  model=$(cat "$d/device/model" 2>/dev/null | tr -d '\n')
  echo "  /dev/$n : ${gib} GiB  model='${model}'"
  if [ "$gib" -ge 3 ] && [ "$gib" -le 16 ]; then
    if [ -n "$TARGET" ]; then echo "ABORT: multiple 3-16 GiB disks found, refusing."; exit 1; fi
    TARGET="/dev/$n"
  fi
done
[ -z "$TARGET" ] && { echo "ABORT: no 3-16 GiB USB disk found - is the SD card in the reader?"; exit 1; }
echo "Selected: $TARGET"
for p in /sys/block/$(basename "$TARGET")/p*; do
  [ -e "$p" ] || continue
  pn=$(basename "$p")
  grep -q " /dev/$(basename "$TARGET")$pn " /proc/mounts && { echo "ABORT: /dev/$(basename "$TARGET")$pn is mounted - unmount first."; exit 1; }
done

echo '=== 2. download image (25.12.6, fallback 24.10.8) ==='
F=""
for v in 25.12.6 24.10.8; do
  f=$(curl -s --max-time 30 "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/" | grep -oE '>[^<]*bpi-r4[^<]*\.img\.gz' | sed 's/^>//' | sort -u | head -1)
  if [ -n "${f:-}" ]; then
    echo "found: $v / $f"
    [ -f "$f" ] || curl -sS --retry 3 -O "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/$f"
    [ -f "$f.sha256sum" ] || curl -sS -O "https://downloads.openwrt.org/releases/$v/targets/rockchip/armv8/$f.sha256sum"
    F="$f"; break
  fi
  echo "  no bpi-r4 image in $v"
done
[ -z "$F" ] && { echo "ABORT: no bpi-r4 image found in either release."; exit 1; }

echo '=== 3. verify checksum ==='
sha256sum -c "$F.sha256sum" || { echo "ABORT: checksum mismatch - not flashing."; exit 1; }

read -r -p "Write '$F' to $TARGET ? type 'flash' to continue: " ans
[ "$ans" = "flash" ] || { echo "Aborted by user."; exit 1; }

echo '=== 4. flashing (a few minutes) ==='
sudo sh -c "zcat '$F' | dd of='$TARGET' bs=4M oflag=sync status=progress"
sync

echo '=== 5. DONE ==='
echo "Image written to $TARGET."
echo "Now:  sudo eject $TARGET   -> remove the SD card -> insert into the BPI-R4 -> power it on."
echo "Then run:  bash ~/bpi-r4-after-sd-boot.sh"
