#!/bin/sh

###############################################################
# Wired AP / repeater node setup.
#
# Pure L2 — no DHCP, no DNS, no routing on this box. The home
# router handles all of that; this node just rebroadcasts the
# LAN and IoT SSIDs and provides one wired LAN access port.
#
# Topology:
#   eth1  = uplink trunk to home router carrying:
#             untagged → LAN (172.20.1.0/24)
#             VLAN 20  → IoT (172.20.2.0/24)
#   eth0  = LAN access port (untagged LAN only — IoT/homelab
#             are NOT exposed here)
#   wifi  = 5GHz LAN SSID  -> br-lan
#           2.4GHz IoT SSID -> br-iot
###############################################################

# Manageable from main LAN. Default OpenWrt config puts this on
# 192.168.x.x; change here so we land on the real LAN subnet
# right away.
uci set network.lan.proto='static'
uci set network.lan.ipaddr='172.20.1.252'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='172.20.1.254'
uci set network.lan.dns='172.20.1.254'
uci set network.lan.ipv6='0'

##############################################################
# Replace the default anonymous br-lan with a named one that
# bridges both the uplink (eth1, untagged LAN) and the wired
# access port (eth0).

i=0
while uci -q get network.@device[$i] >/dev/null 2>&1; do
    name=$(uci -q get network.@device[$i].name 2>/dev/null)
    if [ "$name" = "br-lan" ]; then
        uci delete network.@device[$i]
        break
    fi
    i=$((i+1))
done

uci set network.br_lan='device'
uci set network.br_lan.type='bridge'
uci set network.br_lan.name='br-lan'
uci add_list network.br_lan.ports='eth1'
uci add_list network.br_lan.ports='eth0'
uci set network.lan.device='br-lan'

# This node is NOT a DHCP server — main router does that.
uci set dhcp.lan.ignore='1'

##############################################################
# IoT extension bridge — VLAN 20 lifted off the uplink trunk.
# eth0 is deliberately NOT a member, so wired clients on the
# LAN access port cannot reach IoT.

uci set network.eth1_v20='device'
uci set network.eth1_v20.type='8021q'
uci set network.eth1_v20.ifname='eth1'
uci set network.eth1_v20.vid='20'
uci set network.eth1_v20.name='eth1.20'

uci set network.br_iot='device'
uci set network.br_iot.type='bridge'
uci set network.br_iot.name='br-iot'
uci add_list network.br_iot.ports='eth1.20'

uci set network.iot_ext='interface'
uci set network.iot_ext.proto='none'
uci set network.iot_ext.device='br-iot'

uci commit network
uci commit dhcp

##############################################################
# Firewall zones — security is enforced upstream at the home
# router. Just need zones so OpenWrt doesn't drop forwarded L2
# traffic. The default 'lan' zone already covers br-lan with
# input=ACCEPT, which is what we want for SSH manageability.

uci add firewall zone
uci set firewall.@zone[-1].name='iot_ext'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].network='iot_ext'

uci commit firewall

# Apply
/etc/init.d/network restart
sleep 2
/etc/init.d/firewall restart
