# OpenWrt on the Banana Pi BPI-R4 (router + GPON fiber stick)

The home router. It replaces both the Verizon ONT and the eero:

```
Verizon fiber ──► GPON SFP stick ──► BPI-R4 (OpenWrt: router, firewall, DHCP, Wi-Fi) ──► home LAN
                  (in the R4's SFP cage)
```

Status: in production since 2026-10-24.

## Contents

| Path | What | In git |
|---|---|---|
| [`scripts/`](scripts/) | Run on the Debian server: stick access, provisioning, cutover, rollback, eMMC env rescue | yes |
| [`router/`](router/) | Files installed on the router (`/etc/init.d/gpon-stick`, `/root/*.sh`) | yes |
| [`sfp-patch/`](sfp-patch/) | Tools that binary-patch the kernel's `sfp.ko` (see §4.1) | yes |
| [`docs/`](docs/) | [Clean fix plan](docs/future-sfp-quirk.md), [fiber cutover steps](docs/phase3-cutover-steps.md) (done; reference) | yes |
| [`archive/`](archive/) | Obsolete bring-up scripts from the first eMMC install (reference only) | yes |
| `local/` | Firmware images, config backups, logs, raw dumps, stick firmware, private notes (ONT serial etc.) | **no** (gitignored) |

---

## 1. Hardware

| Item | Details |
|---|---|
| Router | Banana Pi BPI-R4 (MediaTek MT7988A), 4 GB RAM, 8 GB eMMC, 128 MB SPI-NAND |
| Wi-Fi | Banana Pi BE14 card (MediaTek MT7996, Wi-Fi 7). Early batch with a factory defect (§4.3) |
| Fiber stick | iSzo LL-XS2510 = ODI DFP-34X-2C2 (Realtek RTL9601D, firmware V1.0-220923). Reports as `OEM / XPON-Stick`. SC/APC. In SFP cage `sfp2` = Linux port `sfp-lan` |
| Line | Verizon Fios GPON. The stick uses the identity of the replaced Nokia G-211M-C ONT (serial in `local/notes/`) |

### SW3 boot switch (UP = 0, DOWN = 1, A = left, B = right)

| A:B | Boots | Use |
|---|---|---|
| **1:0** (A down, B up) | **eMMC** | **Production. Leave it here.** |
| 0:1 | SPI-NAND | Rescue system (older OpenWrt build, 192.168.1.1, root, blank password) |
| 1:1 | SD card | Not used |
| 0:0 | — | Hangs. Never use. |

---

## 2. Software and configuration

- **Official OpenWrt 25.12.6** (kernel 6.12.112) on eMMC, partition `mmcblk0p5` = 4 GiB. Image in `local/images/`.
  Extra packages: ethtool, curl, tcpdump.
- Recreate the whole configuration on a fresh install: [`scripts/provision-official.sh`](scripts/provision-official.sh)
  (uses the config backup in `local/backup/`), then [`router/cutover.sh`](router/cutover.sh) on the router.

| Item | Value |
|---|---|
| WAN | `sfp-lan.99` (Verizon **VLAN 99**), DHCP + DHCPv6, fixed WAN MAC |
| LAN | `br-lan` (lan1–3): **192.168.4.1/22** + 192.168.1.254/24 (management). DHCP .100–.249 |
| Stick management | Interface `onu`: router 192.168.2.254 → stick **192.168.2.1** (firewall zone `wan`) |
| Wi-Fi | Same SSID/password as the old eero. 2.4 GHz 27 dBm, 5 GHz 23–26 dBm. 6 GHz disabled |
| Port forwards | TCP 22, 80, 443, 25565 → server 192.168.4.51 |

### Fiber stick settings (stored in the stick)

| Key | Value | Why |
|---|---|---|
| `GPON_SN`, `HW_SERIAL_NO` | Nokia ONT serial (`local/notes/`) | Verizon's OLT authorizes this serial |
| `PON_VENDOR_ID` | `ALCL` | Nokia vendor ID |
| `OMCI_FAKE_OK` | `1` | Accept the OLT's OMCI configuration |
| `LAN_IP_ADDR` | `192.168.2.1` | Avoid a clash with the router LAN |
| `LAN_SDS_MODE` | `7` (SGMII force) | The mode that links with the R4 |
| `PON_DETECT_ENABLE`, `RESTORE_DEFAULT_EN` | `0`, `0` | No auto-detect, no "factory reset via fiber" |

---

## 3. Access

| Target | How |
|---|---|
| Router | `ssh root@192.168.4.1` from the server (key auth). Web UI: http://192.168.4.1 (LAN only) |
| Router from outside | `ssh -L 8443:192.168.4.1:443 fernando@ftoralesacosta.me`, then https://localhost:8443 |
| Stick SSH | `scripts/stick.sh '<cmd>' </dev/null` (admin/admin, legacy SSH algorithms, jumps through the router). **Always add `</dev/null`. Never run `diag` without it** (wedges the stick's SSH; recover by rebooting the stick from its web UI) |
| Stick web UI | http://192.168.2.1 (admin/admin). Status page: `status_pon.asp` (want state **O5**) |

Useful checks on the router:
- Boot medium: `dmesg | grep 'mapped 1 uImage.FIT'` → `mmcblk0p5` = eMMC, `ubiblock0_3` = NAND.
- Stick link: `ethtool sfp-lan | grep -E 'Auto-neg|Link det'`; history: `dmesg | grep 'sfp-lan: Link'`.

---

## 4. Non-standard changes (and why)

### 4.1 Patched `sfp.ko`: ignore the stick's "no light" signal
- **Problem:** the stick reports LOS (loss of signal) whenever the fiber is out, so Linux keeps the port
  down and the stick cannot be configured without fiber.
- **Fix:** `/lib/modules/6.12.112/sfp.ko` is binary-patched so an existing quirk (ignore LOS + TX_FAULT)
  matches `OEM / XPON-Stick`. Tool: [`sfp-patch/sfp_patch2.py`](sfp-patch/sfp_patch2.py). In `/etc/sysupgrade.conf`.
- **After an OpenWrt upgrade with a new kernel:** re-patch the new `sfp.ko`. With fiber in, the internet
  works without the patch; only fiber-less stick access needs it.
- Clean long-term fix: [docs/future-sfp-quirk.md](docs/future-sfp-quirk.md).

### 4.2 Service [`router/gpon-stick`](router/gpon-stick) (`/etc/init.d/gpon-stick`)
- **`autoneg` (on):** every 5 s keeps in-band auto-negotiation off on `sfp-lan`
  (`ethtool -s sfp-lan autoneg off`, no speed/duplex arguments). The MediaTek PCS links with this stick only
  with autoneg off, and Linux re-enables it whenever it re-detects the module.
- **`keepalive` (off):** `ping -i 1 192.168.2.1`. The stick's web server has a hidden watchdog that resets the
  link if no frames arrive from the router for ~21 s. Fiber traffic keeps it quiet, so it is disabled by the
  flag file `/etc/gpon-stick.no-keepalive`. Turn it on (e.g. to work on the stick without fiber):
  `rm /etc/gpon-stick.no-keepalive; /etc/init.d/gpon-stick restart`.

### 4.3 BE14 Wi-Fi power fix (one U-Boot variable)
- **Problem:** early BE14 cards have zero 2.4/5 GHz target power in their calibration data → 6–7 dBm
  (OpenWrt issue #17489).
- **Fix:** official OpenWrt ships a device-tree overlay with good calibration data, enabled with
  `fw_setenv bootconf_extra mt7988a-bananapi-bpi-r4-wifi-be14`. Undo: `fw_setenv bootconf_extra` + reboot.
- If the router ever fails to boot because of it: SW3 → 0:1, add `192.168.1.100/24` to the server's cable NIC,
  run [`scripts/rescue-wifi-overlay-from-nand.sh`](scripts/rescue-wifi-overlay-from-nand.sh), SW3 → 1:0.
- Make **no other** U-Boot boot-path edits.

---

## 5. Recovery

| Situation | Action |
|---|---|
| Internet down, router reachable | `ifstatus wan`, `dmesg \| grep sfp-lan`, stick `status_pon.asp` (want O5) |
| Go back to Verizon ONT + eero | [`scripts/rollback-all.sh`](scripts/rollback-all.sh), move the fiber to the Nokia ONT, power the eero |
| eMMC system does not boot | SW3 → 0:1 (NAND system at 192.168.1.1 over the server cable; `sudo ip addr add 192.168.1.100/24 dev enp129s0`), repair the eMMC env (pattern: [`scripts/fix-emmc-env-from-nand.sh`](scripts/fix-emmc-env-from-nand.sh)) |
| Stick SSH wedged | Reboot the stick from its web UI |

---

## 6. Future
1. Build the stick quirk into `kmod-sfp` (replaces §4.1 and the `autoneg` loop): [docs/future-sfp-quirk.md](docs/future-sfp-quirk.md).
2. Optionally reflash the NAND rescue system with official OpenWrt 25.12.x.
3. 6 GHz Wi-Fi: disabled; revisit if a 6 GHz client appears.
4. Retire the eero and Nokia ONT after a few stable weeks.
