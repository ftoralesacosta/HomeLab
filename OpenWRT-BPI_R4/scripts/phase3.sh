#!/usr/bin/env bash
# =============================================================================
# PHASE 3 (v2) — fiber test. The stick is ALREADY programmed and reachable without
# fiber (192.168.2.1 via the BPI-R4). This script only needs the fiber moved.
#   1. preflight (nothing changes)            4. router WAN onto the stick + Verizon DHCP
#   2. you move the fiber ONT -> stick        5. internet test, then: switch over now? (yes)
#   3. wait for O5 (registration), read VLAN  6. otherwise: revert + move the fiber back
# Run on the debian server inside tmux:   bash ~/HomeLab/OpenWRT-BPI_R4/scripts/phase3.sh
# Ctrl-C at any time = safe revert + "move the fiber back". Log: ~/HomeLab/OpenWRT-BPI_R4/local/logs/
# =============================================================================
set -u
ROUTER="192.168.4.1"; STICK_IP="192.168.2.1"
DIR="$HOME/HomeLab/OpenWRT-BPI_R4/scripts"; LOGDIR="$HOME/HomeLab/OpenWRT-BPI_R4/local/logs"; mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d-%H%M%S); LOG="$LOGDIR/phase3-$TS.log"
exec > >(tee -a "$LOG") 2>&1

R() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o LogLevel=ERROR -o ConnectTimeout=6 root@$ROUTER "$@"; }
# stick SSH (through the router). NEVER run 'diag' without </dev/null (it hangs dropbear).
S() { local i; for i in 1 2 3; do timeout 40 "$DIR/stick.sh" "$@" </dev/null && return 0; sleep 5; done; return 1; }
# stick web status (lightweight, no SSH): prints "ONU State O5" etc.
PON() { R "J=/tmp/p3.ck; curl -s -m6 -c \$J -b \$J -o /dev/null -d 'challenge=&username=admin&password=admin&save=Login&submit-url=%2Fadmin%2Flogin.asp' http://$STICK_IP/boaform/admin/formLogin; \
	curl -s -m6 -b \$J http://$STICK_IP/status_pon.asp | sed 's/<[^>]*>/ /g; s/&nbsp;/ /g' | tr -s ' \t\r\n' ' ' | sed -n 's/.*\(Temperature.*Status [A-Za-z ]*\).*/\1/p'" 2>/dev/null; }
say()  { echo; echo "[$(date +%T)] === $* ==="; }
big()  { echo; echo "##############################################################"; \
	 for l in "$@"; do echo "##  $l"; done; \
	 echo "##############################################################"; }
WAN_MOVED=0; RESULT="incomplete"; KEEP=0

cutover_flow() {
	say "CUTOVER: making the BPI-R4 your main router"
	if ! R /root/cutover.sh; then
		echo "cutover.sh FAILED -> rolling the router back"; R /root/rollback.sh; WAN_MOVED=0
		RESULT="stick OK, but the cutover config failed (rolled back)"; return 1
	fi
	big "The BPI-R4 is now serving the home Wi-Fi + the internet." "" \
	    "NOW: 1) unplug the eero's POWER" \
	    "     2) unplug the cable between the BPI-R4 WAN port and the eero (if any)" "" \
	    "Your Mac's SSH session may drop as the eero disappears (expected)." \
	    "Reconnect: Mac rejoins the Wi-Fi by itself -> debian_lan -> tmux attach -t p3" \
	    "Progress is also in: $LOG"
	read -r -p "Press Enter once the eero is unplugged... " _ </dev/tty || true
	say "waiting for the server to reach the internet through the BPI-R4 (up to 6 min)"
	OK=0
	for i in $(seq 1 72); do
		gw=$(ip neigh show 192.168.4.1 2>/dev/null | awk '{print $5}')
		if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && [ -n "$gw" ] && [ "${gw#20:be:cd}" = "$gw" ]; then
			OK=1; echo "server online via the BPI-R4 (gateway MAC $gw) after ~$((i*5))s"; break
		fi
		[ $((i % 6)) = 0 ] && echo "  t=$((i*5))s gateway-mac=${gw:-none} wifi=$(ip -4 -br addr show wlp130s0 | awk '{print $3}')"
		sleep 5
	done
	if [ $OK = 1 ]; then
		PUB=$(R "ifstatus wan | jsonfilter -e '@[\"ipv4-address\"][0].address'")
		echo "public IPv4 on the BPI-R4 WAN: $PUB"
		say "waiting for Cloudflare DDNS to point ftoralesacosta.me at $PUB (up to 8 min)"
		for i in $(seq 1 48); do
			d=$(dig +short ftoralesacosta.me @1.1.1.1 2>/dev/null | tail -1)
			[ "$d" = "$PUB" ] && { echo "DNS updated: ftoralesacosta.me -> $d"; break; }
			[ $((i % 6)) = 0 ] && echo "  DNS still says ${d:-?}"
			sleep 10
		done
		R "wc -l < /tmp/dhcp.leases | xargs echo DHCP clients:; iw dev | grep -c ssid | xargs echo Wi-Fi APs up:"
		big "CUTOVER DONE: the BPI-R4 is your router now. The eero can stay unplugged." \
		    "Tell the agent: 'cutover done' (it checks port forwards/sites from outside)."
	else
		big "The server could not get online through the BPI-R4 within 6 min." "" \
		    "TO UNDO EVERYTHING:  bash ~/HomeLab/OpenWRT-BPI_R4/scripts/rollback-all.sh" \
		    "(it resets the router, then tells you to plug the eero back in" \
		    " and move the fiber back to the Nokia ONT)"
	fi
	echo "Full log: $LOG"
	return 0
}

finish() {
	trap - EXIT INT TERM
	say "wrap-up"
	if [ "$KEEP" = 1 ]; then cutover_flow && exit 0; fi
	if [ "$WAN_MOVED" = 1 ]; then
		echo "reverting router WAN config (stick port back to the LAN bridge)"
		R /root/wan-revert.sh || echo "WARN: wan-revert failed (tell the agent)"
	fi
	big "RESULT: $RESULT" "" \
	    "NOW: move the fiber from the stick BACK to the Nokia ONT." \
	    "(the stick keeps its settings; the eero gets internet back)"
	read -r -p "Press Enter once the fiber is back in the Nokia ONT... " _ </dev/tty || true
	say "waiting for the eero internet to come back (up to 5 min)"
	for i in $(seq 1 60); do
		if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then echo "internet is back after ~$((i*5))s"; break; fi
		sleep 5
	done
	ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || echo "internet NOT back yet — give the ONT/eero a few more minutes, then power-cycle the eero"
	echo; echo "Full log: $LOG"; echo "Tell the agent: 'phase 3 done' — it will read the log."
	exit 0
}
trap finish EXIT
trap 'RESULT="aborted by Ctrl-C"; finish' INT TERM

# ----------------------------------------------------------------------------
say "preflight (nothing changes yet)"
R "echo router OK: \$(uci get network.lan.ipaddr | tr '\n' ' ')" || { RESULT="router unreachable at $ROUTER"; exit 1; }
R "test -x /root/wan-on-stick.sh -a -x /root/wan-revert.sh -a -x /root/cutover.sh -a -x /root/rollback.sh" || { RESULT="router helper scripts missing"; exit 1; }
R "ethtool sfp-lan | grep -E 'Auto-neg|Link det'; dmesg | grep 'sfp-lan: Link' | tail -2"
PON || { RESULT="stick web page not reachable at $STICK_IP"; exit 1; }
S 'for v in GPON_SN HW_SERIAL_NO PON_VENDOR_ID LAN_SDS_MODE OMCI_FAKE_OK PON_DETECT_ENABLE; do flash get $v; done' || echo "(stick SSH busy; web page OK, continuing)"
[ -n "${TMUX:-}" ] && echo "running inside tmux: good" || echo "NOTE: not inside tmux. Recommended: Ctrl-C, 'tmux new -s p3', run again."
if [ "${1:-}" = "--preflight" ]; then RESULT="preflight only (nothing changed)"; trap - EXIT INT TERM; big "$RESULT"; exit 0; fi

big "Unplug the fiber from the Nokia ONT and plug it into the stick" \
    "(green SC/APC connector; push until it clicks)." \
    "Your internet goes down now until the script finishes."
read -r -p "Press Enter once the fiber is in the stick... " _ </dev/tty

# ----------------------------------------------------------------------------
say "1. waiting for PON registration (O5) — up to 6 min"
O5=0; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 360 ]; do
	st=$(PON | tr '\n' ' ')
	echo "  t=$(( $(date +%s) - t0 ))s  $st"
	case "$st" in *"State O5"*) O5=1; break;; esac
	sleep 5
done
say "1b. PON details"
PON
S 'omcicli mib get 84 </dev/null' > "$LOGDIR/me84-$TS.txt" 2>&1; cat "$LOGDIR/me84-$TS.txt"
S 'omcicli mib get 171 </dev/null' > "$LOGDIR/me171-$TS.txt" 2>&1; head -60 "$LOGDIR/me171-$TS.txt"
S 'omcicli mib get 256 </dev/null' > "$LOGDIR/me256-$TS.txt" 2>&1
R "dmesg | grep 'sfp-lan: Link' | tail -4"
[ $O5 = 1 ] || { RESULT="FAILED: no O5 in 6 min (Verizon did not accept the stick). Logs saved."; exit 1; }

VID=$(grep -oiE "VID[^0-9]{0,3}[0-9]+" "$LOGDIR/me84-$TS.txt" | grep -oE "[0-9]+$" | grep -vE "^(0|4095)$" | head -1)
echo "VLAN from ME 84: ${VID:-none found (assume untagged)}"

say "2. moving the router WAN onto the stick and asking Verizon for an IP"
try_wan() {
	R "/root/wan-revert.sh >/dev/null 2>&1; /root/wan-on-stick.sh $1" && WAN_MOVED=1
	for i in $(seq 1 18); do
		ip4=$(R "ifstatus wan | jsonfilter -e '@[\"ipv4-address\"][0].address'" 2>/dev/null)
		[ -n "$ip4" ] && { echo "  WAN got IPv4 $ip4 (mode: ${1:-untagged})"; return 0; }
		sleep 5
	done
	echo "  no DHCP lease in 90s (mode: ${1:-untagged})"; return 1
}
GOT=0
try_wan "" && GOT=1
[ $GOT = 0 ] && [ -n "$VID" ] && try_wan "$VID" && GOT=1
R "ifstatus wan; ifstatus wan6 | head -40" > "$LOGDIR/wan-status-$TS.txt" 2>&1
[ $GOT = 1 ] || { RESULT="FAILED: O5 OK but no DHCP lease (untagged / VID ${VID:-?}). Logs saved."; exit 1; }

say "3. internet test from the router"
R 'ping -c3 -W2 1.1.1.1; nslookup verizon.com 2>&1 | tail -3; curl -s -m8 http://ifconfig.me/ip; echo'
R 'curl -s -o /dev/null -w "download test: %{speed_download} bytes/s over %{time_total}s\n" --max-time 15 http://speedtest.tele2.net/1GB.zip' || true
R "ifstatus wan6 | jsonfilter -e '@[\"ipv6-prefix\"][0].address' -e '@[\"ipv6-prefix\"][0].mask'" || true
RESULT="SUCCESS: stick registered (O5) and the BPI-R4 got a Verizon IP."
big "$RESULT" "" \
    "Choice: switch over to the BPI-R4 NOW (the fiber stays in the stick, the BPI-R4" \
    "takes over Wi-Fi with the same name/password + port forwards, the eero gets unplugged)" \
    "or put the fiber back into the Nokia ONT and switch over another time."
read -r -p "Type 'yes' to switch over now, or just Enter to put the fiber back: " ans </dev/tty || ans=""
[ "$ans" = "yes" ] && KEEP=1
exit 0
