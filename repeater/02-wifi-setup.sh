#!/bin/sh

#################################################################
# WiFi SSIDs matching the home and lab routers for seamless
# 802.11r fast-roaming across all three nodes.
#
# IMPORTANT: MOBILITY_DOMAIN must be exactly 4 hex characters
# (0-9, a-f) AND identical to home/lab routers. Mismatched or
# invalid values silently disable 802.11r — clients fall back
# to full re-auth on roam, and roaming feels janky.
#################################################################

MAIN_SSID="HomeRouter"
MAIN_PASSWORD="YourStrongPassword123"
IOT_SSID="HomeRouter_IoT"
IOT_PASSWORD="YourStrongPassword123"
MOBILITY_DOMAIN="a1b2"

# Channels are PINNED, not 'auto'. Two reasons, both learned on the
# garage node:
#
#  1. ACS runs per-node with no idea the other nodes exist, so every box
#     independently picked 2.4GHz channel 1 — the garage node ended up
#     co-channel with the lab router at -25 dBm, i.e. sharing airtime
#     with it for no reason.
#  2. On 5GHz, ACS happily picks a DFS channel (it chose 112). DFS means
#     a 60s quiet CAC before the AP will beacon at all, and a radar
#     detection drops every 5GHz client and vacates the channel for 30
#     minutes. On a garage/basement node that reads as "the wifi randomly
#     dies" and nothing in the logs looks like a wifi problem.
#
# Pick per node, after surveying FROM that node (it is the only vantage
# point that matters — the main router was inaudible from the garage,
# which is what made 149 the right answer there rather than a clash):
#
#   iw dev phy1-ap0 scan | grep -E '^BSS |freq:|signal:|SSID:'
#   iw list | grep -E '5[0-9]{3}\.0 MHz' | grep -v 'radar detection'
#
# Prefer a non-DFS channel with no strong neighbour. In AU that is
# 36/40/44/48 (23 dBm) or 149/153/157/161/165 (30 dBm).
#
# Current allocation — 2.4GHz keeps the nodes on the 1/6/11 non-overlapping
# trio; 5GHz splits the two non-DFS 80MHz blocks (36-48 and 149-161):
#
#            5GHz            2.4GHz
#   main     149              1
#   lab       40 ('auto')     1     <- still auto, worth pinning
#   garage   149             11     <- main is inaudible there, so 149 is
#                                       clean AND gets the full 30 dBm
#   lounge    36              6     <- lab router is the loud neighbour in
#                                       the 36-48 block; re-survey in situ
CHANNEL_5G="149"
CHANNEL_24G="11"

# Wipe defaults
uci -q delete wireless.default_radio0 2>/dev/null
uci -q delete wireless.default_radio1 2>/dev/null

###############################################################
# radio1 (5GHz) — LAN SSID
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel="$CHANNEL_5G"
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.txpower='30'

uci set wireless.lan_5g='wifi-iface'
uci set wireless.lan_5g.device='radio1'
uci set wireless.lan_5g.mode='ap'
uci set wireless.lan_5g.ssid="$MAIN_SSID"
uci set wireless.lan_5g.encryption='sae'
uci set wireless.lan_5g.key="$MAIN_PASSWORD"
uci set wireless.lan_5g.network='lan'

# 802.11r Fast BSS Transition
uci set wireless.lan_5g.ieee80211r='1'
uci set wireless.lan_5g.mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.lan_5g.ft_over_ds='0'
uci set wireless.lan_5g.ft_psk_generate_local='1'

# 802.11k/v assisted roaming
uci set wireless.lan_5g.ieee80211k='1'
uci set wireless.lan_5g.ieee80211v='1'
uci set wireless.lan_5g.bss_transition='1'
uci set wireless.lan_5g.time_advertisement='2'

###############################################################
# radio0 (2.4GHz) — IoT SSID, bridges to VLAN 20 on the uplink
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='AU'
uci set wireless.radio0.channel="$CHANNEL_24G"
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.txpower='20'

uci set wireless.iot_2g='wifi-iface'
uci set wireless.iot_2g.device='radio0'
uci set wireless.iot_2g.mode='ap'
uci set wireless.iot_2g.ssid="$IOT_SSID"
uci set wireless.iot_2g.encryption='sae-mixed'
uci set wireless.iot_2g.key="$IOT_PASSWORD"
uci set wireless.iot_2g.network='iot_ext'

# 802.11r for IoT roaming
uci set wireless.iot_2g.ieee80211r='1'
uci set wireless.iot_2g.mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.iot_2g.ft_over_ds='0'
uci set wireless.iot_2g.ft_psk_generate_local='1'

# 802.11k/v
uci set wireless.iot_2g.ieee80211k='1'
uci set wireless.iot_2g.ieee80211v='1'
uci set wireless.iot_2g.bss_transition='1'
uci set wireless.iot_2g.time_advertisement='2'

uci commit wireless
wifi
