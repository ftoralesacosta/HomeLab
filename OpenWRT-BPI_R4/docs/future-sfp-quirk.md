# Future project: build the GPON-stick fix into the OpenWrt image

Status: NOT done. Today the fix lives in three local workarounds on the router (see below).
This note describes how to replace them with one small, clean change to OpenWrt.

## The problem, in plain words
The BPI-R4 talks to the GPON fiber stick (iSzo LL-XS2510, reports itself as "OEM XPON-Stick")
through its SFP cage. Linux has a list of "odd" SFP modules and how to treat them. This stick
is not on the list, so Linux treats it like a normal fiber module, and two things go wrong:

1. "No light = no link". A normal module tells the router "no light" when no fiber is plugged
   in, and Linux then keeps the port down. The stick says "no light" whenever its fiber is
   unplugged, so without fiber the router cannot reach the stick at all (no way to configure
   it, no way to see its status).
2. "Wrong handshake". Linux starts the port with a handshake (in-band auto-negotiation) that
   this stick does not answer. Result: no link. Turning the handshake off by hand works, but
   Linux turns it back on every time it re-detects the stick (every boot, every re-plug).

The change adds the stick to Linux's list with two instructions: "ignore its no-light signal"
and "never use the handshake with it". Then both problems disappear at the moment Linux detects
the stick, with no extra scripts.

(A third, unrelated behavior is inside the stick itself: its firmware resets the link if it
sees no traffic from the router for ~21 s while in "SGMII Force" mode. That is handled by a
1-per-second ping and is not fixed by this change. Tested 2026-10-24: NOT needed with fiber; it is off
(see section 4.2 in ../README.md).)

## The code change (one line in the Linux SFP driver, drivers/net/phy/sfp.c)
Add to the sfp_quirks[] table (Linux 6.12 = the kernel inside OpenWrt 25.12):

    // iSzo/LuLeey LL-XS2510 = ODI DFP-34X-2C2 (RTL9601D GPON ONU stick):
    // asserts LOS without fiber (needed for management access) and does not
    // complete in-band autoneg with the MediaTek PCS -> run 1000base-X inband off.
    SFP_QUIRK("OEM", "XPON-Stick", sfp_quirk_disable_autoneg,
              sfp_fixup_ignore_tx_fault_and_los),

Both helper functions already exist in Linux 6.12 (check: sfp_fixup_ignore_tx_fault_and_los;
if it is missing in the exact tree, use sfp_fixup_ignore_los). Upstream precedent: Linux commit
95aca8602ef7 (2026) added the same kind of entry for the sibling "HSGQ" "HSGQ-XPON-Stick".
In OpenWrt this becomes a small patch file, e.g.
target/linux/generic/pending-6.12/7xx-net-sfp-add-quirk-for-OEM-XPON-Stick.patch.

## What it replaces on the router (remove after installing the new image)
- /lib/modules/6.12.112/sfp.ko binary patch (and its line in /etc/sysupgrade.conf)
- the "autoneg" loop in /etc/init.d/gpon-stick (the "keepalive" part is already off since 2026-10-24: fiber traffic
  keeps the stick watchdog quiet)

## Which image to base it on
- UPDATE 2026-10-23: the router now runs OFFICIAL OpenWrt 25.12.6. Previously it ran github.com/IncubusRK/openwrt-bpi-r4 (an automatic
  build of OpenWrt 25.12 with extra packages, e.g. zapret/ruantiblock censorship-bypass tools
  aimed at Russian users). It works, but it is a third-party build.
- Official OpenWrt supports the BPI-R4 directly ("bananapi_bpi-r4", mediatek/filogic) in the
  24.10 and 25.12 release branches (the old handoff said otherwise; that was wrong: the old
  session looked in the rockchip target). Recommended base: the current official 25.12.x
  release from downloads.openwrt.org / firmware-selector.openwrt.org.
- Two ways to add the fix:
  a) Easiest: official 25.12.x image + build ONLY the kmod-sfp package with the official
     OpenWrt SDK for that same release (the SDK produces a module that matches the official
     kernel), then `apk add` it on the router. Re-do after each OpenWrt upgrade.
  b) Cleanest long-term: send the patch to OpenWrt (and/or upstream Linux netdev) so it ships
     in official images for everyone.
- Moving from the IncubusRK image to official OpenWrt: same device profile and flash layout,
  so a sysupgrade with the official *-squashfs-sysupgrade.itb works. Prefer a fresh config
  (sysupgrade -n) and re-apply settings, because the package sets differ.
- Side note: the board is sold as 8 GB RAM but only 4 GB is visible with the standard
  bootloader. Official OpenWrt also builds 8 GB ("-4bg"/"_8g") bootloader variants; check this
  in the same project.
