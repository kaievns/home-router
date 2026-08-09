#!/bin/sh

###############################################################
# Work-laptop SSID extension (VLAN 40) for repeater nodes.
#
# Identical in shape to lab-router/06-work-network.sh: pure L2, VLAN 40
# lifted off the uplink trunk, no IP on this box for that network. All
# firewalling lives on the main router.
#
# Topology reminder (see 01-network-setup.sh):
#   eth1 = uplink trunk   — untagged LAN, VLAN 20 IoT, VLAN 40 work
#   eth0 = wired LAN access port — untagged LAN ONLY
#
# eth0 is deliberately not a member of br-work-ext: the wired access
# port stays plain LAN.
#
# See home-router/11-work-network.sh for the full rationale.
###############################################################

WORK_SSID="HomeRouter_Work"
WORK_PASSWORD="YourStrongPassword123"   # <- DO NOT commit the real one

# See the note in home-router/11-work-network.sh — hidden is not a
# security win here and costs roaming quality. Must match the other nodes.
WORK_HIDDEN="0"

# Must be 4 hex chars and identical across all nodes carrying this SSID.
MOBILITY_DOMAIN="a1b2"

##############################################################
# VLAN 40 off the uplink trunk
uci set network.eth1_v40='device'
uci set network.eth1_v40.type='8021q'
uci set network.eth1_v40.ifname='eth1'
uci set network.eth1_v40.vid='40'
uci set network.eth1_v40.name='eth1.40'

uci set network.br_work_ext='device'
uci set network.br_work_ext.type='bridge'
uci set network.br_work_ext.name='br-work-ext'
uci add_list network.br_work_ext.ports='eth1.40'

uci set network.work_ext='interface'
uci set network.work_ext.proto='none'
uci set network.work_ext.device='br-work-ext'

uci commit network

##############################################################
# Zone exists only so OpenWrt doesn't drop the bridged L2 traffic.
uci set firewall.work_ext_zone='zone'
uci set firewall.work_ext_zone.name='work_ext'
uci set firewall.work_ext_zone.input='REJECT'
uci set firewall.work_ext_zone.output='ACCEPT'
uci set firewall.work_ext_zone.forward='ACCEPT'
uci set firewall.work_ext_zone.network='work_ext'

uci commit firewall

##############################################################
# WiFi — 5GHz work SSID, bridged onto VLAN 40.
uci set wireless.work_5g='wifi-iface'
uci set wireless.work_5g.device='radio1'
uci set wireless.work_5g.mode='ap'
uci set wireless.work_5g.ssid="$WORK_SSID"
uci set wireless.work_5g.encryption='sae-mixed'
uci set wireless.work_5g.key="$WORK_PASSWORD"
uci set wireless.work_5g.network='work_ext'
uci set wireless.work_5g.hidden="$WORK_HIDDEN"
uci set wireless.work_5g.isolate='1'

# 802.11r/k/v — must match the other nodes for clean roaming.
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
# Apply. reload/`wifi reload` rather than full restarts — see the note in
# home-router/11-work-network.sh.
/etc/init.d/network reload
sleep 2
/etc/init.d/firewall restart
wifi reload
