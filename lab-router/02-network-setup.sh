#!/bin/sh


# Set the router IP to 172.16.1.254 (end of the range)
uci set network.lan.ipaddr='172.16.1.254'

# Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

# Configure radio1 (5GHz) - main network
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.txpower='20' # 16dBm antennas
uci set wireless.default_radio1.ssid='Homelab'
uci set wireless.default_radio1.encryption='sae'
uci set wireless.default_radio1.key='YourStrongPassword123'
uci set wireless.default_radio1.network='lan'

# Configure radio0 (2.4GHz) - IoT network
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='AU'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.txpower='20'
uci set wireless.default_radio0.ssid='Homelab_IoT'
uci set wireless.default_radio0.encryption='sae'
uci set wireless.default_radio0.key='YourStrongPassword123'
uci set wireless.default_radio0.network='iot'

uci commit wireless
wifi

# the homelab router specific setup to switch WAN to wifi backhaul

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
wifi

# swapping WAN from eth1 to wifin
uci show network.wan.device

# Delete the ethernet device association
uci delete network.wan.device

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
