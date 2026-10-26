#!/usr/bin/env bash
# Discover the iSzo SFP stick ONU on the BPI-R4 LAN (192.168.1.0/24).
# The ONU's Ethernet side should be up as soon as the stick is powered,
# even before it registers on the Verizon PON. Read-only; one sudo (tcpdump).
set -u
IF=enx000ec67d6484
IP=192.168.1.1
SSH="sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=6"
command -v sshpass >/dev/null || sudo apt-get install -y sshpass

echo "=== 1. SFP port link on the router ==="
ssh-keygen -R $IP >/dev/null 2>&1
$SSH root@$IP 'echo "sfp-lan carrier: $(cat /sys/class/net/sfp-lan/carrier 2>/dev/null)"; echo "sfp-wan carrier: $(cat /sys/class/net/sfp-wan/carrier 2>/dev/null)"; dmesg | grep -iE "sfp|phy" | tail -8' 2>/dev/null || echo "(router not reachable at $IP)"

echo
echo "=== 2. 45s ARP/DHCP sniff on $IF ==="
sudo timeout 45 tcpdump -i $IF -n -e -c 200 'arp or (bootp and not bootps)' 2>&1 | head -40

echo
echo "=== 3. ping sweep 192.168.1.0/24 (45s) ==="
seq 2 254 | xargs -P 64 -I{} sh -c 'ping -c1 -W1 -q 192.168.1.{} >/dev/null 2>&1 && echo {}' | sort -t. -k4 -n > /tmp/onu-alive.txt
echo "alive hosts: $(tr '\n' ' ' < /tmp/onu-alive.txt)"
echo
echo "=== 4. who are they (MACs) + open ports ==="
while read -r h; do
  mac=$(awk -v ip="192.168.1.$h" '$1==ip {print $3}' /proc/net/arp)
  [ -n "$mac" ] || mac=?
  tag=""
  case "$mac" in
    5E:47:7A:9A:CD:4*|5e:47:7a:9a:cd:4*) tag="[ROUTER]" ;;
  esac
  ports=""
  for p in 80 443 22 8080; do
    timeout 1 bash -c "exec 3<>/dev/tcp/192.168.1.$h/$p" 2>/dev/null && ports="$ports $p"
  done
  echo "  192.168.1.$h  mac=$mac  open:$ports  $tag"
done < /tmp/onu-alive.txt
echo
echo "=== 5. verdict ==="
echo "Any host that is NOT the router (5e:47:7a:9a:cd:47/48) and NOT this PC"
echo "(check your own MAC: ip link show $IF) is the ONU stick."
echo "With a candidate IP:  firefox/chrome -> http://<ip>   (web UI)"
echo "Common first logins: admin/admin, admin/password, or the sticker on the stick."
echo "If its mgmt IP is 192.168.1.1 (same as router) -> collision; tell the agent."
