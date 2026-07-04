#!/bin/sh
#
# Read-only diagnostics for the lab (homelab) router.
# Does not change any state — safe to run any time.
#
# Usage: ssh root@172.20.3.253 'sh -s' < lab-router/99-diagnostics.sh
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
sec "Network interfaces"
#############################################################
for iface_ip in "lan:172.16.1.254" "wan:172.20.3.253" "iot:172.16.2.254"; do
    iface="${iface_ip%:*}"; expected="${iface_ip#*:}"
    actual=$(uci -q get network.$iface.ipaddr)
    [ "$actual" = "$expected" ] && pass "$iface = $actual" || fail "$iface = '$actual' (expected $expected)"
done

#############################################################
sec "VLAN devices on trunk"
#############################################################
for dev in eth1 eth1.20 eth1.30; do
    if ip link show "$dev" >/dev/null 2>&1; then
        operstate=$(cat /sys/class/net/$dev/operstate 2>/dev/null)
        [ "$operstate" = "up" ] && pass "$dev exists, up" || warn "$dev exists but state=$operstate"
    else
        fail "$dev missing"
    fi
done

#############################################################
sec "Bridges"
#############################################################
for br in br-lan br-lan-ext br-iot-ext; do
    if ip link show "$br" >/dev/null 2>&1; then
        pass "$br exists"
    else
        fail "$br missing"
    fi
done

#############################################################
sec "Connectivity"
#############################################################
ping -c 1 -W 2 172.20.3.254 >/dev/null 2>&1 && pass "ping home router (172.20.3.254)" || fail "ping home router"
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && pass "ping 1.1.1.1 (internet)" || fail "ping 1.1.1.1"
ping -c 1 -W 2 172.20.1.254 >/dev/null 2>&1 && pass "ping home LAN router IP" || warn "home LAN router IP unreachable"

#############################################################
sec "Firewall zones"
#############################################################
for z in lan wan lan_ext iot_ext iot; do
    found=$(uci show firewall 2>/dev/null | grep -c "\.name='$z'")
    [ "$found" -ge 1 ] && pass "zone $z declared" || fail "zone $z missing"
done

#############################################################
sec "NAT bypass: preserve home-LAN→homelab source IPs"
#############################################################
[ "$(uci -q get firewall.lan_to_homelab_nonat)" = "nat" ] && pass "UCI section declared" || fail "UCI section missing"
egress=$(uci -q get firewall.lan_to_homelab_nonat.src)
case "$egress" in
    lan) pass "src=lan (correct egress zone)" ;;
    wan) fail "src=wan (wrong egress — forward direction exits via lan)" ;;
    *)   warn "src='$egress' (unexpected)" ;;
esac
# Check the rule actually exists in srcnat_lan
if nft list chain inet fw4 srcnat_lan 2>/dev/null | grep -q "172.20.1.0/24.*172.16.1.0/24"; then
    cnt=$(nft list chain inet fw4 srcnat_lan 2>/dev/null | grep "172.20.1.0/24.*172.16.1.0/24" | grep -oE 'packets [0-9]+' | awk '{print $2}')
    pass "rule live in srcnat_lan (packets matched: ${cnt:-0})"
    [ "${cnt:-0}" -eq 0 ] && info "no traffic matched yet — try connecting from home LAN to a homelab host to verify"
else
    fail "rule NOT in srcnat_lan — fw4 didn't generate it"
fi

#############################################################
sec "WiFi APs"
#############################################################
for iface in lan_5g iot_2g homelab_2g; do
    if [ -n "$(uci -q get wireless.$iface.ssid)" ]; then
        ssid=$(uci -q get wireless.$iface.ssid)
        pass "$iface SSID='$ssid'"
    else
        fail "$iface missing"
    fi
done
# mobility_domain
for iface in lan_5g iot_2g; do
    val=$(uci -q get wireless.$iface.mobility_domain)
    if echo "$val" | grep -qE '^[0-9a-fA-F]{4}$'; then
        pass "$iface mobility_domain='$val' (must match home router)"
    else
        fail "$iface mobility_domain='$val' invalid"
    fi
done
# At least one client associated on each AP?
for phy_ap in phy0-ap0 phy1-ap0; do
    sta_count=$(iw dev "$phy_ap" station dump 2>/dev/null | grep -c '^Station')
    info "$phy_ap stations: $sta_count"
done

#############################################################
sec "Static route to homelab MetalLB"
#############################################################
ip route show 172.16.1.0/24 | head -1 | grep -q "172.16.1.254\|via 172.20.3.253\|dev br-lan" && pass "172.16.1.0/24 routable" || warn "static route check ambiguous"

#############################################################
sec "Trunk monitoring metrics freshness"
#############################################################
for f in trunk_latency trunk_health; do
    file="/var/prometheus/${f}.prom"
    age=$(fresh "$file" 120)
    case "$age" in
        missing) fail "$f.prom missing" ;;
        *) [ "$?" -eq 0 ] && pass "$f.prom fresh ($age)" || warn "$f.prom stale ($age)" ;;
    esac
done
pgrep -f /usr/bin/alloy >/dev/null && pass "alloy running" || fail "alloy NOT running"
pgrep -f prometheus-node-exporter >/dev/null && pass "node exporter running" || fail "node exporter NOT running"

#############################################################
sec "IPv6 actually disabled"
#############################################################
v6=$(ip -6 addr show 2>/dev/null | grep -c 'inet6 [^f]')
[ "$v6" -eq 0 ] && pass "no global IPv6 addresses" || warn "$v6 IPv6 addresses present"

#############################################################
sec "rc.local sanity (legacy NAT bypass should be gone)"
#############################################################
if grep -q '172.20.1.0/24.*172.16.1.0/24' /etc/rc.local 2>/dev/null; then
    warn "old raw nft rule still in /etc/rc.local — remove it (UCI handles this now)"
else
    pass "/etc/rc.local clean of legacy NAT bypass"
fi

#############################################################
echo
echo "═══════════════════════════════════════════════"
echo "  Summary: $OK pass, $WARN warn, $FAIL fail"
echo "═══════════════════════════════════════════════"
[ $FAIL -eq 0 ]
