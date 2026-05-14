#!/bin/sh
#
# Read-only diagnostics for the home (main) router.
# Does not change any state — safe to run any time.
#
# Usage: ssh root@172.20.1.254 'sh -s' < home-router/99-diagnostics.sh
#

OK=0; FAIL=0; WARN=0
pass() { echo "  PASS  $*"; OK=$((OK+1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  WARN  $*"; WARN=$((WARN+1)); }
info() { echo "  INFO  $*"; }
sec()  { echo; echo "── $* ──"; }

fresh() {  # fresh <file> <max_age_seconds>
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
for iface_ip in "lan:172.20.1.254" "iot:172.20.2.254" "homelab:172.20.3.254"; do
    iface="${iface_ip%:*}"; expected="${iface_ip#*:}"
    actual=$(uci -q get network.$iface.ipaddr)
    [ "$actual" = "$expected" ] && pass "$iface = $actual" || fail "$iface = '$actual' (expected $expected)"
done
# WAN should have a public IP
wan_ip=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
if [ -n "$wan_ip" ]; then pass "wan has IP: $wan_ip"; else fail "wan has no IP"; fi

#############################################################
sec "Connectivity"
#############################################################
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && pass "ping 1.1.1.1" || fail "ping 1.1.1.1"
ping -c 1 -W 2 172.20.3.253 >/dev/null 2>&1 && pass "ping lab router (172.20.3.253)" || warn "lab router unreachable (may be off)"
nslookup google.com 127.0.0.1 >/dev/null 2>&1 && pass "DNS via local resolver" || fail "DNS via local resolver"

#############################################################
sec "DNS stack (AdGuard on :53, dnsmasq on :54)"
#############################################################
netstat -tlnp 2>/dev/null | grep -q ":53 .*AdGuard" && pass "AdGuard on :53" || fail "AdGuard NOT on :53"
netstat -tlnp 2>/dev/null | grep -q ":54 .*dnsmasq" && pass "dnsmasq on :54" || fail "dnsmasq NOT on :54"
pgrep -f AdGuardHome >/dev/null && pass "AdGuard process running" || fail "AdGuard process NOT running"

#############################################################
sec "mDNS reflector (avahi)"
#############################################################
pgrep -f avahi-daemon >/dev/null && pass "avahi-daemon running" || fail "avahi-daemon NOT running"
grep -q 'enable-reflector=yes' /etc/avahi/avahi-daemon.conf 2>/dev/null && pass "reflector enabled" || fail "reflector NOT enabled"
for iface in br-lan br-iot br-homelab; do
    grep -q "allow-interfaces=.*\b${iface}\b" /etc/avahi/avahi-daemon.conf && pass "$iface in allow-interfaces" || warn "$iface NOT in allow-interfaces"
done
# Firewall rules so avahi receives mDNS from iot/homelab zones
for z in iot homelab; do
    if nft list chain inet fw4 "input_${z}" 2>/dev/null | grep -q "udp dport 5353.*accept"; then
        pass "Allow-${z}-mDNS in input"
    else
        fail "Allow-${z}-mDNS MISSING (iPhone won't see IoT devices)"
    fi
done

#############################################################
sec "Firewall zones & forwarding"
#############################################################
for z in lan iot homelab wan; do
    uci -q get firewall.@zone[0] >/dev/null 2>&1 && true
    found=$(uci show firewall 2>/dev/null | grep -c "\.name='$z'")
    [ "$found" -ge 1 ] && pass "zone $z declared" || fail "zone $z missing"
done
# Required forwards
for fwd in "lan→iot" "lan→homelab" "iot→wan" "homelab→wan"; do
    src="${fwd%→*}"; dst="${fwd#*→}"
    if uci show firewall 2>/dev/null | grep -q "forwarding.*\.src='$src'" && \
       uci show firewall 2>/dev/null | awk "/\.src='$src'/,/^$/" | grep -q "\.dest='$dst'"; then
        pass "$fwd"
    else
        # Fallback: simple grep
        if uci show firewall | grep -B1 "\.dest='$dst'" | grep -q "\.src='$src'"; then
            pass "$fwd"
        else
            fail "$fwd missing"
        fi
    fi
done

#############################################################
sec "Firehol blocklist (UCI-managed)"
#############################################################
[ "$(uci -q get firewall.firehol_set)" = "ipset" ] && pass "firewall.firehol_set" || fail "firewall.firehol_set"
for r in fh_in fh_fwd_src fh_fwd_dst; do
    [ "$(uci -q get firewall.$r)" = "rule" ] && pass "rule $r declared" || fail "rule $r missing"
    [ "$(uci -q get firewall.$r.proto)" = "all" ] && pass "$r proto=all" || warn "$r proto≠all (only blocks tcp/udp)"
done
in=$(nft list chain inet fw4 input 2>/dev/null | grep -c firehol_blocklist)
fw=$(nft list chain inet fw4 forward 2>/dev/null | grep -c firehol_blocklist)
[ $in -eq 1 ] && pass "input nft rule live" || fail "input rule got $in, expect 1"
[ $fw -eq 2 ] && pass "forward nft rules live" || fail "forward rules got $fw, expect 2"
n=$(ipset list firehol_blocklist 2>/dev/null | grep -c '^[0-9]')
[ "$n" -gt 1000 ] && pass "ipset populated ($n entries)" || warn "ipset has $n entries (run firehol-refresh.sh)"
ls /etc/rc.d/S*firehol* >/dev/null 2>&1 && pass "init.d enabled" || fail "init.d not enabled"
grep -q 'ipset restore' /usr/bin/firehol-refresh.sh 2>/dev/null && \
   ! grep -q 'ensure_rule' /usr/bin/firehol-refresh.sh && \
   pass "refresh script is current version" || fail "refresh script is old/missing"

#############################################################
sec "Earlier patches still applied"
#############################################################
grep -q 'LOCK_FILE="/tmp/packet-loss.lock"' /usr/bin/packet-loss.sh 2>/dev/null && pass "packet-loss.sh lock guard" || fail "packet-loss.sh lock guard missing"
i=0; bad=0
while uci -q get "dhcp.@host[$i]" >/dev/null 2>&1; do
    [ -z "$(uci -q get dhcp.@host[$i].mac 2>/dev/null)" ] && bad=$((bad+1))
    i=$((i+1))
done
[ $bad -eq 0 ] && pass "no MAC-less dhcp host entries" || fail "$bad MAC-less host entries"
for r in default_radio0 default_radio1; do
    val=$(uci -q get wireless.$r.mobility_domain)
    if echo "$val" | grep -qE '^[0-9a-fA-F]{4}$'; then
        pass "$r mobility_domain='$val'"
    else
        fail "$r mobility_domain='$val' invalid"
    fi
done

#############################################################
sec "Static routes / homelab reachability"
#############################################################
ip route show 172.16.1.0/24 | grep -q "via 172.20.3.253" && pass "static route to 172.16.1.0/24" || warn "static route missing or lab router off"

#############################################################
sec "IPv6 actually disabled"
#############################################################
v6=$(ip -6 addr show 2>/dev/null | grep -c 'inet6 [^f]')
[ "$v6" -eq 0 ] && pass "no global IPv6 addresses" || warn "$v6 IPv6 addresses present"
sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q '^1$' && pass "ipv6 disabled in sysctl" || warn "ipv6 not sysctl-disabled"

#############################################################
sec "Observability: textfile metrics freshness"
#############################################################
for f in isp-packetloss isp-wanip adguard bandwidth device_status new_devices; do
    file="/var/prometheus/${f}.prom"
    age=$(fresh "$file" 300)
    case "$age" in
        missing) fail "$f.prom missing" ;;
        *) [ "$?" -eq 0 ] && pass "$f.prom fresh ($age)" || warn "$f.prom stale ($age)" ;;
    esac
done
pgrep -f promtail >/dev/null && pass "promtail running" || fail "promtail NOT running"
pgrep -f prometheus-node-exporter >/dev/null && pass "node exporter running" || fail "node exporter NOT running"

#############################################################
sec "Recent log noise (last 1000 lines)"
#############################################################
pkt_overlap=$(logread | tail -1000 | grep -c 'process already running')
dhcp_crash=$(logread | tail -1000 | grep -c uci_dhcp_host)
firehol_err=$(logread | tail -1000 | grep -c "firehol_ipset.*ERROR")
last_pkt=$(logread | grep 'process already running' | tail -1 | awk '{print $1,$2,$3,$4}')
last_dhcp=$(logread | grep uci_dhcp_host | tail -1 | awk '{print $1,$2,$3,$4}')

[ "$pkt_overlap" -eq 0 ] && pass "no packet-loss overlap" || info "packet-loss overlap count: $pkt_overlap (last: ${last_pkt:-none})"
[ "$dhcp_crash" -eq 0 ] && pass "no uci_dhcp_host crashes" || info "uci_dhcp_host crash count: $dhcp_crash (last: ${last_dhcp:-none})"
[ "$firehol_err" -eq 0 ] && pass "no firehol errors" || warn "firehol errors: $firehol_err"

#############################################################
echo
echo "═══════════════════════════════════════════════"
echo "  Summary: $OK pass, $WARN warn, $FAIL fail"
echo "═══════════════════════════════════════════════"
[ $FAIL -eq 0 ]
