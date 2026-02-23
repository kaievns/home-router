#!/bin/sh


#################################################################
# Main WiFi Roaming SSIDs + Homelab_IoT SSID
#################################################################

MAIN_SSID="Bilabonga"
MAIN_PASSWORD="santaisosom"
IOT_SSID="Bilabonga_IoT"
IOT_PASSWORD="santaisosom"
MOBILITY_DOMAIN="l0lz"  # same 4-hex-char on both routers

HOMELAB_IOT_SSID="Homelab_IoT"
HOMELAB_IOT_PASSWORD="sylviaandlucas"

###############################################################
# Blowing away the default config for the radios and interfaces to start clean
uci delete wireless.default_radio0 2>/dev/null
uci delete wireless.default_radio1 2>/dev/null


###############################################################
# radio1 (5GHz) — LAN SSID (roaming with main router)
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.txpower='30' # 3dBm antennas

uci set wireless.lan_5g='wifi-iface'
uci set wireless.lan_5g.device='radio1'
uci set wireless.lan_5g.mode='ap'
uci set wireless.lan_5g.ssid="$MAIN_SSID"
uci set wireless.lan_5g.encryption='sae'
uci set wireless.lan_5g.key="$MAIN_PASSWORD"
uci set wireless.lan_5g.network='lan_ext'

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
# radio0 (2.4GHz) — IoT SSID (roaming) + Homelab IoT SSID
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='AU'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.txpower='20'

# IoT SSID — bridges to VLAN 20 (main router's IoT network)
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

# 802.11k/v for IoT
uci set wireless.iot_2g.ieee80211k='1'
uci set wireless.iot_2g.ieee80211v='1'
uci set wireless.iot_2g.bss_transition='1'
uci set wireless.iot_2g.time_advertisement='2'

###############################################################
# Homelab internal IoT SSID — bridges to the homelab IoT (eth0, 172.16.2.0/24)
uci set wireless.homelab_2g='wifi-iface'
uci set wireless.homelab_2g.device='radio0'
uci set wireless.homelab_2g.mode='ap'
uci set wireless.homelab_2g.ssid="$HOMELAB_IOT_SSID"
uci set wireless.homelab_2g.encryption='sae-mixed'
uci set wireless.homelab_2g.key="$HOMELAB_IOT_PASSWORD"
uci set wireless.homelab_2g.network='iot'
uci set wireless.homelab_2g.hidden='1'

uci commit wireless
wifi