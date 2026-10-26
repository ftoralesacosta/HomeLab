#!/usr/bin/env bash
# OPTIONAL but very useful: capture the serial console while testing one SW3 state.
# Usage (at the board, CH340G plugged into the PC):  bash ~/bpi-r4-serial-state.sh D
# Steps: 1) set switches to state D  2) run this  3) power the board ON
#        4) watch the log; when you see a login prompt (or after ~2 min): Ctrl-A then X
#        5) the script then auto-detects what booted and records it.
set -u
STATE="${1:?usage: bpi-r4-serial-state.sh A|B|C|D}"
command -v picocom >/dev/null || { echo "first: sudo apt-get install -y picocom"; exit 1; }
T=$(ls /dev/ttyUSB* 2>/dev/null | head -1)
[ -n "$T" ] || { echo "no /dev/ttyUSB* found - plug in the CH340G module first"; exit 1; }
LOG=~/bpi-r4-probe/serial-$STATE.log
mkdir -p ~/bpi-r4-probe
echo "Serial: $T @115200  ->  log: $LOG"
echo "Set SW3 to state $STATE, then POWER ON the board now."
echo "(If garbled: swap the TX/RX wires. If silent: check GND.)"
picocom -b 115200 -l "$LOG" "$T"
echo "--- picocom exited; saving log, now detecting what booted ---"
bash ~/bpi-r4-probe-which-media.sh "$STATE"
