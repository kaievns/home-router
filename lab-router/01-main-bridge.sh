#!/bin/sh

################################################################
# This is the main bridge router that connects the main LAN, IoT, 
# and homelab networks together across the trunk link
################################################################

##############################################################
# VLAN devices on eth1 (trunk port)

# VLAN 20 device — IoT traffic
uci set network.eth1_v20='device'
uci set network.eth1_v20.type='8021q'
uci set network.eth1_v20.ifname='eth1'
uci set network.eth1_v20.vid='20'
uci set network.eth1_v20.name='eth1.20'

# VLAN 30 device — Homelab WAN uplink
uci set network.eth1_v30='device'
uci set network.eth1_v30.type='8021q'
uci set network.eth1_v30.ifname='eth1'
uci set network.eth1_v30.vid='30'
uci set network.eth1_v30.name='eth1.30'

##############################################################
# LAN extension bridge (untagged on trunk = main router's LAN)

# Bridge for LAN roaming — pure L2, no IP on this router
uci set network.br_lan_ext='device'
uci set network.br_lan_ext.type='bridge'
uci set network.br_lan_ext.name='br-lan-ext'
uci add_list network.br_lan_ext.ports='eth1'

# Note: eth1 (untagged) carries LAN traffic from the trunk.
# The 5GHz WiFi LAN SSID will also join this bridge.

uci set network.lan_ext='interface'
uci set network.lan_ext.proto='none'
uci set network.lan_ext.device='br-lan-ext'

##############################################################
# IoT extension bridge (VLAN 20 on trunk = main router's IoT)

uci set network.br_iot_ext='device'
uci set network.br_iot_ext.type='bridge'
uci set network.br_iot_ext.name='br-iot-ext'
uci add_list network.br_iot_ext.ports='eth1.20'

uci set network.iot_ext='interface'
uci set network.iot_ext.proto='none'
uci set network.iot_ext.device='br-iot-ext'

uci commit network


##############################################################
# The LAN extension and IoT extension are pure L2 bridges.
# They don't need firewall zones on this router because traffic
# flows through at layer 2 and the main router's firewall handles it.
#
# However, we do need zones so OpenWrt doesn't drop the traffic.

# LAN extension zone — allow everything (it's the main router's LAN)
uci add firewall zone
uci set firewall.@zone[-1].name='lan_ext'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].network='lan_ext'

# IoT extension zone — allow everything at L2 (main router firewalls it)
uci add firewall zone
uci set firewall.@zone[-1].name='iot_ext'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].network='iot_ext'

uci commit firewall