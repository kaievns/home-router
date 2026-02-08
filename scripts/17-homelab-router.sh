#!/bin/sh

# the homelab router specific setup to switch WAN to wifi backhaul

cp /etc/config/wireless /etc/config/wireless.bak
cp /etc/config/network /etc/config/network.bak
cp /etc/config/firewall /etc/config/firewall.bak
cp /etc/config/dhcp /etc/config/dhcp.bak

# Remove the existing 5GHz AP interface
uci delete wireless.default_radio1

# Create STA interface for backhaul
uci set wireless.wwan=wifi-iface
uci set wireless.wwan.device='radio1'
uci set wireless.wwan.mode='sta'
uci set wireless.wwan.ssid='Name_Homelab'
uci set wireless.wwan.encryption='sae'
uci set wireless.wwan.key='YourHomelabPasswordHere'
uci set wireless.wwan.network='wan'

# Hide the SSID
uci set wireless.default_radio0.hidden='1'
uci set wireless.radio0.channel='auto'

uci commit wireless

# swapping WAN from eth1 to wifin
uci show network.wan.device

# Delete the ethernet device association
uci delete network.wan.device

uci set network.wan.proto='static'
uci set network.wan.ipaddr='172.20.3.253'
uci set network.wan.netmask='255.255.255.0'
uci set network.wan.gateway='172.20.3.254'
#uci set network.wan.dns='172.20.3.254'

# bypassing the main router adguard
uci set network.wan.dns='8.8.8.8'

uci commit network

/etc/init.d/network restart
