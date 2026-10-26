#!/usr/bin/env bash
# STAGE 0: download OpenWrt 25.12 (BPI-R4) and flash the SD card.
set -u
IMG_DIR="$HOME/bpi-r4-images"; mkdir -p "$IMG_DIR"; cd "$IMG_DIR"
REL='https://github.com/IncubusRK/openwrt-bpi-r4/releases/download/2026.07.28-2221-25.12'
IMG='openwrt-mediatek-filogic-bananapi_bpi-r4-sdcard.img.gz'
ITB='openwrt-mediatek-filogic-bananapi_bpi-r4-squashfs-sysupgrade.itb'

echo '=== 1. locate SD card (expect ~7 GiB "STORAGE DEVICE") ==='
TARGET=""
for d in /sys/block/sd*; do
  n=$(basename "$d")
  sectors=$(cat "$d/size" 2>/dev/null || echo 0)
  gib=$(( sectors * 512 / 1073741824 ))
  model=$(cat "$d/device/model" 2>/dev/null | tr -d '\n')
  echo "  /dev/$n : ${gib} GiB  model='$model'"
  if [ "$gib" -ge 3 ] && [ "$gib" -le 16 ]; then
    if [ -n "$TARGET" ]; then echo "ABORT: multiple 3-16 GiB disks found."; exit 1; fi
    TARGET="/dev/$n"
  fi
done
[ -z "$TARGET" ] && { echo "ABORT: no 3-16 GiB USB disk found - is the SD card in the reader?"; exit 1; }
echo "Selected: $TARGET"
for p in /sys/block/$(basename "$TARGET")/p*; do
  [ -e "$p" ] || continue
  pn=$(basename "$p")
  grep -q " /dev/$(basename "$TARGET")$pn " /proc/mounts && { echo "ABORT: /dev/$(basename "$TARGET")$pn is mounted."; exit 1; }
done

echo '=== 2. download (38 MB image + 37 MB sysupgrade for later) ==='
[ -f "$IMG" ] || curl -sSL --retry 3 -o "$IMG" "$REL/$IMG"
[ -f "$ITB" ] || curl -sSL --retry 3 -o "$ITB" "$REL/$ITB"
ls -la "$IMG" "$ITB"

echo '=== 3. integrity + extracted size ==='
gzip -t "$IMG" && echo 'gzip: OK' || { echo "ABORT: corrupt image"; exit 1; }
EXTRACTED=$(zcat "$IMG" | wc -c)
echo "extracted image size: ${EXTRACTED} bytes ($(( EXTRACTED / 1048576 )) MiB)"

read -r -p "Write '$IMG' to $TARGET ? type 'flash' to continue: " ans
[ "$ans" = "flash" ] || { echo "Aborted by user."; exit 1; }

echo '=== 4. flashing ==='
sudo sh -c "zcat '$IMG_DIR/$IMG' | dd of='$TARGET' bs=4M oflag=sync status=progress"
sync
echo '=== 5. DONE ==='
cat <<'NEXT'
Now do the PHYSICAL steps:
  1) sudo eject    (then remove the SD card)
  2) On the BPI-R4, find the SW3 boot switches (two slide switches on the PCB)
     and set them to 1:1  (BOTH in the LOWER position) = boot from SD
  3) Insert the SD card, power the BPI-R4 on (2.5-3 min for first boot + NAND copy)
  4) Then run:  bash ~/bpi-r4-step1-sd2nand.sh
NEXT
