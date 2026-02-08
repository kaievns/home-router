#!/bin/sh

# adding Google's bbr tcp traffic controller
opkg update && opkg install kmod-tcp-bbr

echo bbr > /proc/sys/net/ipv4/tcp_congestion_control
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# Set the router IP to 172.20.1.254 (end of the range)
uci set network.lan.ipaddr='172.20.1.254'
#uci set network.lan.ipaddr='172.16.1.254' # for homelab router

# Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

# Configure DHCP range (172.20.1.1 to 172.20.1.253)
uci set dhcp.lan.start='1'
uci set dhcp.lan.limit='253'
uci set dhcp.lan.leasetime='12h'

uci commit

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

