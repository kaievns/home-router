#!/bin/sh


# Set the router IP to 172.16.1.254 (end of the range)
uci set network.lan.ipaddr='172.16.1.254'

# Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

# WAN is now VLAN 30 on the trunk (routed, not bridged)
uci set network.wan.device='eth1.30'
uci set network.wan.proto='static'
uci set network.wan.ipaddr='172.20.3.253'
uci set network.wan.netmask='255.255.255.0'
uci set network.wan.gateway='172.20.3.254'
uci set network.wan.dns='172.20.3.254'

uci commit network

/etc/init.d/network restart

# allowing access from the main router LAN network
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='wan'
uci set firewall.@forwarding[-1].dest='lan'
uci commit firewall
/etc/init.d/firewall restart

# Skip NAT for home LAN → homelab traffic (preserves source IPs)
nft insert rule inet fw4 srcnat ip saddr 172.20.1.0/24 ip daddr 172.16.1.0/24 accept

cat >> /etc/rc.local << 'EOF'
# Preserve client source IPs for home LAN reaching homelab
nft insert rule inet fw4 srcnat ip saddr 172.20.1.0/24 ip daddr 172.16.1.0/24 accept
EOF

# patching dropbear to allow SSH access from the main router LAN
uci delete dropbear.@dropbear[0].Interface
uci commit dropbear
/etc/init.d/dropbear restart

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-SSH-from-Home'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].src_ip='172.20.1.0/24'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
