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
# On 5GHz at HE80 the PRIMARY CHANNEL NUMBER IS NOT THE THING THAT
# MATTERS — the 80MHz block is. Channels 36/40/44/48 are all the same
# 80MHz channel (centre 5210), and 149/153/157/161 are all the same one
# (centre 5775). Two APs on "36" and "40" overlap 100%; they are not
# adjacent, they are identical. Compare `center1:`, not `channel`:
#
#   iw dev phy1-ap0 info | grep -E 'channel|center1'
#
# AU has exactly TWO non-DFS 80MHz blocks (36-48 @ 23 dBm, 149-161 @ 30
# dBm). With four APs you therefore CANNOT give everyone a unique block —
# reuse is mandatory, and the only question is which pairs are far enough
# apart to share one. Allocate by physical separation, not by hunting for
# unused numbers.
#
# The deciding measurement is how loud the other APs are FROM THE NODE
# BEING PLACED — the node's own vantage point is the only one that counts:
#
#   iw dev phy1-ap0 scan | awk '/^BSS /{b=$2} /freq: /{f=$2} \
#     /signal: /{g=$2} /SSID: /{if(f>5000) print f, g" dBm", $2, b}' | sort -k2 -rn
#
# Measured 2026-08-16, each from the node's installed position:
#
#            5GHz  centre        2.4GHz   why
#   main      149   5775  30dBm    1
#   lab        36   5210  23dBm    1
#   garage     149  5775  30dBm   11      main inaudible from the garage,
#                                          so 149 is clean AND gets 30 dBm
#   lounge     36   5210  23dBm    6      shares the block with lab, but
#                                          they hear each other at -94/-95
#                                          dBm i.e. not at all. Moving the
#                                          lounge to 149 was TRIED AND
#                                          REJECTED: from the lounge the
#                                          main router is -73 dBm, so 149
#                                          is the LOUDER neighbour by 20 dB.
#
# Sharing a block is fine when the two APs cannot hear each other; that is
# spatial reuse, not a collision. Do not "fix" an overlap on paper without
# measuring it first.
#
# Cosmetic gotcha: both 36-block nodes report `channel 40 (5200 MHz)` from
# `iw` while their UCI and hostapd.conf both say 36. Same centre, same
# block, no operational difference — don't chase it.
#
# STILL OUTSTANDING: main and lab are both 2.4GHz 'auto' and have both
# independently landed on channel 1 — exactly the ACS problem described
# above. Pin them to 1 and 11 (or 11 and 1) whenever those boxes can next
# take a `wifi reload radio0`.
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
