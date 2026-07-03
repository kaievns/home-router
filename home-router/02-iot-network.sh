#!/bin/sh

###############################################################
# This is a setup for IoT network with a separate subnet and 
# firewall rules. It can only access the Internet
#
# __NOTE:__ this network is bridged to VLAN 20 on the trunk
# to make it available across two routers on the network
################################################################

# VLAN 20 device — carries IoT traffic
uci set network.eth0_v20='device'
uci set network.eth0_v20.type='8021q'
uci set network.eth0_v20.ifname='eth0'
uci set network.eth0_v20.vid='20'
uci set network.eth0_v20.name='eth0.20'

# Ensure IoT has an explicit bridge device with the trunk VLAN port.
# When WiFi interfaces specify network='iot', OpenWrt adds them to this bridge.
uci set network.br_iot='device'
uci set network.br_iot.type='bridge'
uci set network.br_iot.name='br-iot'
uci add_list network.br_iot.ports='eth0.20'

# Create IoT interface with IP 172.20.2.254 (end of range)
uci set network.iot='interface'
uci set network.iot.proto='static'
uci set network.iot.device='br-iot'
uci set network.iot.ipaddr='172.20.2.254'
uci set network.iot.netmask='255.255.255.0'
uci set network.iot.ipv6='0'

# Configure DHCP for IoT network
uci set dhcp.iot='dhcp'
uci set dhcp.iot.interface='iot'
uci set dhcp.iot.start='1'
uci set dhcp.iot.limit='253'
uci set dhcp.iot.leasetime='12h'
uci set dhcp.iot.dhcpv6='disabled'
uci set dhcp.iot.ra='disabled'
uci add_list dhcp.iot.dhcp_option='6,172.20.2.254'

uci commit network
uci commit dhcp

# Create IoT firewall zone
uci add firewall zone
uci set firewall.@zone[-1].name='iot'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].network='iot'

# Allow IoT → WAN (Internet access)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='iot'
uci set firewall.@forwarding[-1].dest='wan'

# Allow LAN → IoT (main network can access IoT devices)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='iot'

# Allow DNS and DHCP from IoT to router
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-DNS'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-DHCP'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='67'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow mDNS to reach avahi reflector on the router.
# Without this, IoT-side service announcements (AirPlay/AirPrint/Chromecast)
# never reach avahi and discovery from LAN silently fails.
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-mDNS'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='5353'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow AirPlay 2 PTP clock-sync from an IoT TV back to the LAN.
#
# AirPlay 2 streaming phone(LAN)->TV(IoT) fails at a black screen even
# though discovery + control handshake succeed. Reason: the TV acts as
# PTP grandmaster and sends UNSOLICITED clock-sync packets on UDP 319/320
# BACK to the phone. That's a new IoT->LAN flow with no conntrack state,
# so the iot zone's forward=REJECT drops it, the phone's clock never
# locks, and the session times out (~10-15s). The forward path
# (phone->TV) is already covered by the blanket lan->iot forwarding.
#
# Scope to the TV's IP only — do NOT open all of IoT->LAN. Give the TV a
# DHCP reservation first so <TV_IP> can't drift to another IoT device.
# dest='lan' already binds this to br-lan (172.20.1.0/24); no dest_ip
# needed. This is UDP-only; no TCP return rule is required.
#
# If 319/320 alone still stutters/fails, capture on br-lan during a cast:
#   tcpdump -ni br-lan -vv 'udp portrange 319-320 and host <PHONE_IP>'
# If the TV uses MULTICAST PTP (224.0.1.129-132) no unicast rule helps
# (needs a PTP relay). If it needs a receiver RTCP back-channel, add a
# SEPARATE contained rule: src_ip=<TV_IP> dest_ip=<PHONE_IP> udp
# 49152-65535 — never a wide all-IoT range.
#
# uci add firewall rule
# uci set firewall.@rule[-1].name='Allow-IoT-AirPlay-PTP'
# uci set firewall.@rule[-1].src='iot'
# uci set firewall.@rule[-1].dest='lan'
# uci set firewall.@rule[-1].src_ip='<TV_IP>'
# uci set firewall.@rule[-1].proto='udp'
# uci set firewall.@rule[-1].dest_port='319-320'
# uci set firewall.@rule[-1].target='ACCEPT'

# Explicitly block SSH from IoT zone
uci add firewall rule
uci set firewall.@rule[-1].name='Block-IoT-SSH'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='REJECT'

uci commit firewall

# Restart everything
/etc/init.d/network restart
/etc/init.d/firewall restart
