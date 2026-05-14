#!/bin/sh
#
# Read-only diagnostics for the repeater / wired AP node.
# Does not change any state — safe to run any time.
#
# Usage: ssh root@172.20.1.252 'sh -s' < repeater/99-diagnostics.sh
#

OK=0; FAIL=0; WARN=0
pass() { echo "  PASS  $*"; OK=$((OK+1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  WARN  $*"; WARN=$((WARN+1)); }
info() { echo "  INFO  $*"; }
sec()  { echo; echo "── $* ──"; }

fresh() {
    [ -f "$1" ] || { echo "missing"; return 1; }
    age=$(( $(date +%s) - $(date -r "$1" +%s 2>/dev/null || stat -c %Y "$1") ))
    echo "${age}s"
    [ "$age" -le "$2" ]
}

#############################################################
sec "Identity"
#############################################################
host=$(uci -q get system.@system[0].hostname)
[ -n "$host" ] && info "hostname: $host" || warn "hostname unset"
info "uptime: $(uptime | awk -F'up ' '{print $2}' | awk -F, '{print $1,$2}')"

#############################################################
sec "Network: manageable on main LAN"
#############################################################
lan_ip=$(uci -q get network.lan.ipaddr)
[ "$lan_ip" = "172.20.1.252" ] && pass "lan IP = 172.20.1.252" || fail "lan IP = '$lan_ip' (expected 172.20.1.252)"
[ "$(uci -q get network.lan.gateway)" = "172.20.1.254" ] && pass "gateway = home router" || fail "gateway wrong"
[ "$(uci -q get dhcp.lan.ignore)" = "1" ] && pass "DHCP server disabled (main router serves)" || fail "DHCP server NOT disabled — will fight main router"

#############################################################
sec "Bridges"
#############################################################
# br-lan must bridge eth1 (uplink trunk) + eth0 (LAN access port)
for port in eth1 eth0; do
    if bridge link show 2>/dev/null | grep "^[0-9]*: $port" | grep -q 'master br-lan'; then
        pass "$port in br-lan"
    elif ls /sys/class/net/br-lan/brif/$port >/dev/null 2>&1; then
        pass "$port in br-lan"
    else
        fail "$port not in br-lan"
    fi
done
# br-iot must have eth1.20 only (NOT eth0 — IoT must not leak to wired LAN port)
if ls /sys/class/net/br-iot/brif/eth1.20 >/dev/null 2>&1; then
    pass "eth1.20 in br-iot"
else
    fail "eth1.20 not in br-iot"
fi
if ls /sys/class/net/br-iot/brif/eth0 >/dev/null 2>&1; then
    fail "eth0 IS in br-iot — IoT is leaking to wired LAN port!"
else
    pass "eth0 NOT in br-iot (correct — IoT isolated from wired port)"
fi

#############################################################
sec "VLAN device"
#############################################################
if ip link show eth1.20 >/dev/null 2>&1; then
    operstate=$(cat /sys/class/net/eth1.20/operstate 2>/dev/null)
    [ "$operstate" = "up" ] && pass "eth1.20 up" || warn "eth1.20 state=$operstate"
else
    fail "eth1.20 missing"
fi

#############################################################
sec "Connectivity"
#############################################################
ping -c 1 -W 2 172.20.1.254 >/dev/null 2>&1 && pass "ping home router" || fail "ping home router"
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && pass "ping 1.1.1.1 (internet)" || fail "ping 1.1.1.1"
nslookup google.com 172.20.1.254 >/dev/null 2>&1 && pass "DNS via home router" || warn "DNS lookup failed"

#############################################################
sec "Firewall zones"
#############################################################
for z in lan iot_ext; do
    found=$(uci show firewall 2>/dev/null | grep -c "\.name='$z'")
    [ "$found" -ge 1 ] && pass "zone $z declared" || fail "zone $z missing"
done

#############################################################
sec "WiFi APs"
#############################################################
for iface in lan_5g iot_2g; do
    if [ -n "$(uci -q get wireless.$iface.ssid)" ]; then
        ssid=$(uci -q get wireless.$iface.ssid)
        net=$(uci -q get wireless.$iface.network)
        pass "$iface SSID='$ssid' → network=$net"
    else
        fail "$iface missing"
    fi
done
# Must NOT have a homelab SSID
if uci -q get wireless.homelab_2g >/dev/null 2>&1; then
    fail "homelab SSID present (repeater shouldn't broadcast homelab)"
else
    pass "no homelab SSID (correct)"
fi
# mobility_domain
for iface in lan_5g iot_2g; do
    val=$(uci -q get wireless.$iface.mobility_domain)
    if echo "$val" | grep -qE '^[0-9a-fA-F]{4}$'; then
        pass "$iface mobility_domain='$val' (must match other routers)"
    else
        fail "$iface mobility_domain='$val' invalid"
    fi
done
# Station counts
for phy_ap in phy0-ap0 phy1-ap0; do
    sta=$(iw dev "$phy_ap" station dump 2>/dev/null | grep -c '^Station')
    [ -n "$sta" ] && info "$phy_ap stations: $sta"
done

#############################################################
sec "Uplink monitoring metrics freshness"
#############################################################
for f in uplink_latency uplink_health; do
    file="/var/prometheus/${f}.prom"
    age=$(fresh "$file" 120)
    case "$age" in
        missing) fail "$f.prom missing" ;;
        *) [ "$?" -eq 0 ] && pass "$f.prom fresh ($age)" || warn "$f.prom stale ($age)" ;;
    esac
done
pgrep -f promtail >/dev/null && pass "promtail running" || fail "promtail NOT running"
pgrep -f prometheus-node-exporter >/dev/null && pass "node exporter running" || fail "node exporter NOT running"

#############################################################
sec "IPv6 actually disabled"
#############################################################
v6=$(ip -6 addr show 2>/dev/null | grep -c 'inet6 [^f]')
[ "$v6" -eq 0 ] && pass "no global IPv6 addresses" || warn "$v6 IPv6 addresses present"

#############################################################
sec "Bonus: who's plugged in?"
#############################################################
# Anyone on the eth0 access port? Look at bridge fdb learned on eth0.
n=$(bridge fdb show br br-lan 2>/dev/null | grep ' dev eth0 ' | grep -v 'self\|permanent' | wc -l)
[ -n "$n" ] && info "eth0 (LAN access port) learned MACs: $n"

#############################################################
echo
echo "═══════════════════════════════════════════════"
echo "  Summary: $OK pass, $WARN warn, $FAIL fail"
echo "═══════════════════════════════════════════════"
[ $FAIL -eq 0 ]
