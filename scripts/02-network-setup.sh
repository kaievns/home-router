#!/bin/sh

# Set the router IP to 172.20.1.254 (end of the range)
uci set network.lan.ipaddr='172.20.1.254'

# Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

# Configure DHCP range (172.20.1.1 to 172.20.1.253)
uci set dhcp.lan.start='1'
uci set dhcp.lan.limit='253'
uci set dhcp.lan.leasetime='12h'

uci commit

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

