# BPI-R4 cutover — tonight's steps (updated 2026-10-23 22:30, official OpenWrt 25.12.6)

Status: router + stick are fully set up and tested remotely. The router-to-stick link is
stable (fixed today). The only remaining unknown needs the fiber: does Verizon accept the
stick (registration "O5"), and does the router get an internet address through it.
The stick needs no more programming.

## Before you start (optional, recommended)
- USB-tether your phone to the Mac and keep the Mac's Wi-Fi on the eero. Then the agent
  stays online during the fiber test and can watch/fix things live.
- Check that the fiber patch cable (now in the Nokia ONT) reaches the stick in the BPI-R4.
- Nothing else to cable: the server <-> BPI-R4 LAN cable stays. The BPI-R4 WAN <-> eero
  cable can stay too (you unplug the eero only at the switchover).

## The fiber test + switchover (one script, ~5-15 min of internet outage)
1. On the Mac:  `debian_lan`  ->  `tmux new -s p3`  ->  `bash ~/HomeLab/OpenWRT-BPI_R4/scripts/phase3.sh`
   (if the SSH session drops later: `debian_lan` -> `tmux attach -t p3`)
2. When asked: move the fiber from the Nokia ONT into the stick (green connector, click).
   Press Enter. Your internet is down from here.
3. Wait. The script shows the stick's state every 5 s (O1 ... O5), up to 6 min. Then it
   reads the VLAN from Verizon, moves the router's WAN onto the stick, and tests the
   internet.
4. SUCCESS -> it asks: type `yes` to switch over now:
   - the BPI-R4 turns on Wi-Fi (the eero SSID) (same password), LAN 192.168.4.1/22,
     port forwards 22/80/443/25565 -> the server;
   - when told: unplug the eero's POWER (and the BPI-R4 WAN <-> eero cable);
   - the Mac/server rejoin the Wi-Fi by themselves; reconnect with debian_lan + tmux attach;
   - the script waits for internet + DNS update. Then tell the agent "cutover done".
   If the switchover does not come online in 6 min: `bash ~/HomeLab/OpenWRT-BPI_R4/scripts/rollback-all.sh`.
5. FAILURE (or you press Enter instead of yes) -> it reverts the router and shows
   "move the fiber BACK": put the fiber back into the Nokia ONT, press Enter, internet
   returns. Tell the agent "phase 3 done" — the logs have everything it needs.

Ctrl-C at any time = safe revert + "move the fiber back".
