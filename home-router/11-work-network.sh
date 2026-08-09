#!/bin/sh

###############################################################
# Isolated network for the corporate work laptop.
#
# Threat model: the laptop is a managed corporate machine running
# endpoint agents / inventory scanners we don't control. We want it
# to have internet + a couple of homelab services, and NOTHING else:
# no view of the LAN, no view of IoT, no ability to enumerate the
# homelab, no access to this router's management surface.
#
# __NOTE:__ bridged to VLAN 40 on the trunk so the SSID can be
# rebroadcast by the lab router and the repeater nodes.
#
#   main router  : this file          — routes + firewalls VLAN 40
#   lab router   : 06-work-network.sh — pure L2 extension
#   repeaters    : 04-work-network.sh — pure L2 extension
#
# Uses NAMED uci sections throughout, so re-running is idempotent
# (the older `uci add firewall zone` style duplicates on re-run).
###############################################################

WORK_SSID="Bilabonga_Work"
WORK_PASSWORD="sylvielukieleo"   # <- DO NOT commit the real one

# Broadcast vs hidden. Hidden does NOT improve security here: the SSID
# is in the clear in every association frame anyway. What it *does* do
# is force the client to probe for the network BY NAME wherever it goes
# — office, cafe, airport — so a corporate endpoint agent logging wifi
# telemetry ends up recording your home SSID. It also slows roaming
# across the three nodes (no passive discovery). Set to '0' to broadcast.
WORK_HIDDEN="0"

# Must be 4 hex chars and identical across all nodes carrying this SSID.
MOBILITY_DOMAIN="a1b2"

# The single homelab endpoint the laptop is allowed to reach.
# This is the ingress — everything .homelab resolves here and is routed
# by Host header behind it.
HOMELAB_INGRESS="172.16.1.69"

##############################################################
# VLAN 40 device — carries work traffic on the trunk
uci set network.eth0_v40='device'
uci set network.eth0_v40.type='8021q'
uci set network.eth0_v40.ifname='eth0'
uci set network.eth0_v40.vid='40'
uci set network.eth0_v40.name='eth0.40'

# Explicit bridge so the WiFi iface (network='work') has something to
# join alongside the trunk VLAN port.
uci set network.br_work='device'
uci set network.br_work.type='bridge'
uci set network.br_work.name='br-work'
uci add_list network.br_work.ports='eth0.40'

uci set network.work='interface'
uci set network.work.proto='static'
uci set network.work.device='br-work'
uci set network.work.ipaddr='172.20.4.254'
uci set network.work.netmask='255.255.255.0'
uci set network.work.ipv6='0'

##############################################################
# DHCP.
#
# DNS deliberately points at PUBLIC resolvers, not this router:
#
#  1. dnsmasq answers reverse (PTR) lookups for RFC1918 addresses from
#     its own lease table. `bogus-priv` only stops those being FORWARDED
#     upstream — it does not stop dnsmasq answering them. So a laptop
#     using our resolver can PTR-sweep 172.20.1.0/24 and walk out with a
#     list of every hostname on the LAN. Public DNS closes that.
#  2. It keeps AdGuard from blocking corporate telemetry endpoints, which
#     is the sort of thing that lands on someone's compliance dashboard.
#
# Cost: the laptop can't resolve .homelab names, so add the ones it needs
# to the laptop's own hosts file pointing at HOMELAB_INGRESS.
#
# If the laptop's hosts file is MDM-locked, swap to the router resolver
# below and accept the PTR-enumeration caveat above.
uci set dhcp.work='dhcp'
uci set dhcp.work.interface='work'
uci set dhcp.work.start='10'
uci set dhcp.work.limit='100'
uci set dhcp.work.leasetime='12h'
uci set dhcp.work.dhcpv6='disabled'
uci set dhcp.work.ra='disabled'
uci -q delete dhcp.work.dhcp_option
uci add_list dhcp.work.dhcp_option='6,9.9.9.9,1.1.1.1'
# uci add_list dhcp.work.dhcp_option='6,172.20.4.254'   # router resolver instead

uci commit network
uci commit dhcp

##############################################################
# Firewall zone — default deny in every direction.
#
# Note there is deliberately NO `lan -> work` forwarding, unlike IoT.
# We never need to reach into this network, and leaving it out means a
# compromised LAN host can't use it as a pivot either.
uci set firewall.work_zone='zone'
uci set firewall.work_zone.name='work'
uci set firewall.work_zone.input='REJECT'
uci set firewall.work_zone.output='ACCEPT'
uci set firewall.work_zone.forward='REJECT'
uci set firewall.work_zone.network='work'

# Work → WAN (internet). Picks up MASQUERADE from the wan zone.
uci set firewall.work_to_wan='forwarding'
uci set firewall.work_to_wan.src='work'
uci set firewall.work_to_wan.dest='wan'

# DHCP to this router (the only input we actually need).
uci set firewall.work_dhcp='rule'
uci set firewall.work_dhcp.name='Allow-Work-DHCP'
uci set firewall.work_dhcp.src='work'
uci set firewall.work_dhcp.dest_port='67'
uci set firewall.work_dhcp.proto='udp'
uci set firewall.work_dhcp.target='ACCEPT'

# Gateway ping. Some corporate VPN clients do a gateway reachability
# check before dialling out, and it makes debugging from the laptop sane.
uci set firewall.work_ping='rule'
uci set firewall.work_ping.name='Allow-Work-Ping'
uci set firewall.work_ping.src='work'
uci set firewall.work_ping.proto='icmp'
uci set firewall.work_ping.icmp_type='echo-request'
uci set firewall.work_ping.target='ACCEPT'

##############################################################
# Homelab access — allow-listed by DESTINATION, not by zone forwarding.
#
# IMPORTANT: do NOT do this with a `work -> homelab` zone forwarding.
# The lab router carries a blanket `wan -> lan` forward (see
# lab-router/02-network-setup.sh), so anything that reaches VLAN 30
# gets the run of all of 172.16.1.0/24 — k8s nodes, MinIO admin, the
# lab router's own SSH. Scoping by dest_ip here is what actually
# contains it, and it also means the laptop can't sweep the /24.
#
# Traffic arrives at the lab router from 172.20.4.0/24, which is NOT in
# the no-NAT exemption (that's scoped to 172.20.1.0/24), so it gets
# SNAT'd to 172.16.1.254 on the way in. Fine for HTTP; just means
# homelab-side logs show the router IP rather than the laptop's.
uci set firewall.work_homelab='rule'
uci set firewall.work_homelab.name='Allow-Work-Homelab-Ingress'
uci set firewall.work_homelab.src='work'
uci set firewall.work_homelab.dest='homelab'
uci set firewall.work_homelab.dest_ip="$HOMELAB_INGRESS"
uci set firewall.work_homelab.proto='tcp'
uci set firewall.work_homelab.dest_port='80 443'
uci set firewall.work_homelab.target='ACCEPT'

# Explicit block on this router's management surface. Redundant with
# input='REJECT' above, but stated so the intent survives someone
# loosening the zone default later. Mirrors Block-IoT-SSH.
# (AdGuard doesn't even bind 172.20.4.254, and dnsmasq's DNS is on 54,
# so :53 is already dead here — this is belt and braces.)
uci set firewall.work_block_router='rule'
uci set firewall.work_block_router.name='Block-Work-Router-Services'
uci set firewall.work_block_router.src='work'
uci set firewall.work_block_router.dest_port='22 53 80 443 3030 9100'
uci set firewall.work_block_router.proto='tcp udp'
uci set firewall.work_block_router.target='REJECT'

uci commit firewall

##############################################################
# WiFi — 5GHz, joins br-work via network='work'.
#
# sae-mixed rather than plain sae: MDM-pushed wifi profiles on corporate
# machines are often still WPA2-only. Tighten to 'sae' once you've
# confirmed the laptop associates.
uci set wireless.work_5g='wifi-iface'
uci set wireless.work_5g.device='radio1'
uci set wireless.work_5g.mode='ap'
uci set wireless.work_5g.ssid="$WORK_SSID"
uci set wireless.work_5g.encryption='sae-mixed'
uci set wireless.work_5g.key="$WORK_PASSWORD"
uci set wireless.work_5g.network='work'
uci set wireless.work_5g.hidden="$WORK_HIDDEN"
# AP-level client isolation. No-op with a single device, but stops any
# second device that joins this SSID from seeing the laptop, and vice versa.
uci set wireless.work_5g.isolate='1'

# 802.11r/k/v — same mobility domain as the other SSIDs, so the laptop
# roams cleanly between the three nodes carrying this SSID.
uci set wireless.work_5g.ieee80211r='1'
uci set wireless.work_5g.mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.work_5g.ft_over_ds='0'
uci set wireless.work_5g.ft_psk_generate_local='1'
uci set wireless.work_5g.ieee80211k='1'
uci set wireless.work_5g.ieee80211v='1'
uci set wireless.work_5g.bss_transition='1'
uci set wireless.work_5g.time_advertisement='2'

uci commit wireless

##############################################################
# DELIBERATELY NOT DONE — do not "fix" these later:
#
#  * br-work is NOT added to avahi's allow-interfaces in
#    01-network-setup.sh. The mDNS reflector would otherwise hand the
#    laptop's inventory agent a complete live list of every printer, TV,
#    HomeKit device and Chromecast in the house — names, models, service
#    types — with no scanning required. This is the single biggest leak
#    the whole setup avoids. allow-interfaces is an allowlist, so the
#    default is already correct; just never add br-work to it.
#
#  * No Allow-Work-mDNS firewall rule (the IoT/homelab equivalent), for
#    the same reason.
#
#  * No `lan -> work` forwarding.

##############################################################
# Apply.
#
# `network reload` rather than `restart`: adding a VLAN device, a bridge and
# an interface does not require tearing down the existing ones, and a full
# restart bounces WAN — which on this ISP has previously needed the link
# manually kicked before it would re-establish. reload brings up the new
# sections and leaves lan/wan alone.
#
# `wifi reload` rather than `wifi` for the same reason — it still bounces
# radio1 briefly (unavoidable when adding an SSID to it), but doesn't take
# both radios all the way down.
/etc/init.d/network reload
sleep 2
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
wifi reload

##############################################################
# TRUNK: VLAN 40 must be permitted on the switch ports between this
# router and the lab router / repeaters. If the managed switch has a
# tagged-VLAN allow-list on those trunk ports, add 40 — otherwise the
# SSID comes up fine on the other nodes but DHCP silently never
# completes, which looks like a wifi problem and isn't.
#
# Verify from the laptop's subnet:
#   ip -4 addr show br-work
#   nft list chain inet fw4 forward | grep -i work
# and from the laptop itself:
#   curl -s -o /dev/null -w '%{http_code}\n' http://<name>.homelab   # 200/30x
#   nmap -sn 172.20.1.0/24                                           # nothing
#   ping 172.16.1.254                                                # rejected
