#!/bin/sh

###################################################################
# My wifi is set as 2.4GHz for IoT devices and 5GHz for everything else. Adjust as needed.
# The 5GHz network is set to channel 149 which is usually less congested and
# there is also fast roaming enabled for seamless connectivity across the house.
###################################################################

MAIN_SSID="HomeRouter"
MAIN_PASSWORD="YourStrongPassword123"
IOT_SSID="HomeRouter_IoT"
IOT_PASSWORD="YourStrongPassword123"
MOBILITY_DOMAIN="a1b2"  # same 4-hex-char on both routers

# # separate SSID for homelab backhaul, hidden and isolated from main network
# HOMELAB_SSID="Name_Homelab"
# HOMELAB_PASSWORD="YourHomelabPasswordHere"


# Configure radio1 (5GHz) - main network
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.txpower='30' # 3dBm antennas
uci set wireless.default_radio1.ssid="$MAIN_SSID"
uci set wireless.default_radio1.encryption='sae'
uci set wireless.default_radio1.key="$MAIN_PASSWORD"
uci set wireless.default_radio1.network='lan'

# 802.11r Fast BSS Transition
uci set wireless.default_radio1.ieee80211r='1'
uci set wireless.default_radio1.mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.default_radio1.ft_over_ds='0'
uci set wireless.default_radio1.ft_psk_generate_local='1'

# 802.11k/v for assisted roaming
uci set wireless.default_radio1.ieee80211k='1'
uci set wireless.default_radio1.ieee80211v='1'
uci set wireless.default_radio1.bss_transition='1'
uci set wireless.default_radio1.time_advertisement='2'

# Configure radio0 (2.4GHz) - IoT network
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='AU'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.txpower='20'
uci set wireless.default_radio0.ssid="$IOT_SSID"
uci set wireless.default_radio0.encryption='sae-mixed'
uci set wireless.default_radio0.key="$IOT_PASSWORD"
uci set wireless.default_radio0.network='iot'

# 802.11r for IoT roaming
uci set wireless.default_radio0.ieee80211r='1'
uci set wireless.default_radio0.mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.default_radio0.ft_over_ds='0'
uci set wireless.default_radio0.ft_psk_generate_local='1'

# 802.11k/v for IoT
uci set wireless.default_radio0.ieee80211k='1'
uci set wireless.default_radio0.ieee80211v='1'
uci set wireless.default_radio0.bss_transition='1'
uci set wireless.default_radio0.time_advertisement='2'


# # Add second 5GHz SSID for homelab backhaul on radio1
# uci add wireless wifi-iface
# uci set wireless.@wifi-iface[-1].device='radio1'
# uci set wireless.@wifi-iface[-1].mode='ap'
# uci set wireless.@wifi-iface[-1].ssid="$HOMELAB_SSID"
# uci set wireless.@wifi-iface[-1].encryption='sae'
# uci set wireless.@wifi-iface[-1].key="$HOMELAB_PASSWORD"
# uci set wireless.@wifi-iface[-1].network='homelab'
# uci set wireless.@wifi-iface[-1].isolate='1'
# uci set wireless.@wifi-iface[-1].hidden='1'


uci commit wireless
wifi
