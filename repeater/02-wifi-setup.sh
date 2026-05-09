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

# Wipe defaults
uci -q delete wireless.default_radio0 2>/dev/null
uci -q delete wireless.default_radio1 2>/dev/null

###############################################################
# radio1 (5GHz) — LAN SSID
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel='auto'
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
uci set wireless.radio0.channel='auto'
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
