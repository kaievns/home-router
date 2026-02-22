#!/bin/sh

uci set system.@system[0].hostname='YourNewName'
uci commit system
/etc/init.d/system restart

# adding Google's bbr tcp traffic controller
opkg update && opkg install kmod-tcp-bbr

echo bbr > /proc/sys/net/ipv4/tcp_congestion_control
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# Distribute NIC interrupts across all CPU cores
uci set network.globals.packet_steering='1'

# Configure DHCP range (x.x.x.x to x.x.x.253)
uci set dhcp.lan.start='1'
uci set dhcp.lan.limit='253'
uci set dhcp.lan.leasetime='12h'

# Expand conntrack table for multi-subnet + monitoring load
echo "net.netfilter.nf_conntrack_max=32768" >> /etc/sysctl.conf
sysctl -p

uci commit

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

# Enable software flow offloading (reduces latency for routed traffic)
# NOTE: if SQM/CAKE is added on WAN later, this must be disabled
uci set firewall.@defaults[0].flow_offloading='1'
uci commit firewall
/etc/init.d/firewall restart
