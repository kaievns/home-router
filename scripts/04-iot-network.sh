#!/bin/sh

# Create IoT interface with IP 172.20.2.254 (end of range)
uci set network.iot='interface'
uci set network.iot.proto='static'
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

uci commit firewall

# Restart everything
/etc/init.d/network restart
/etc/init.d/firewall restart
wifi
