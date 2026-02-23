#!/bin/sh

################################################################
# This is a setup for homelab network with a separate subnet and 
# firewall rules. It can only access the Internet, and only accessible 
# from the main LAN (not IoT)
#
# __NOTE:__ this network is bridged to VLAN 30 on the trunk
# to make it available across two routers on the network
################################################################

# VLAN 30 device — carries homelab traffic
uci set network.eth0_v30='device'
uci set network.eth0_v30.type='8021q'
uci set network.eth0_v30.ifname='eth0'
uci set network.eth0_v30.vid='30'
uci set network.eth0_v30.name='eth0.30'

# Create bridge for homelab that includes the VLAN trunk
uci set network.br_homelab='device'
uci set network.br_homelab.type='bridge'
uci set network.br_homelab.name='br-homelab'
uci add_list network.br_homelab.ports='eth0.30'

# Homelab backhaul network
uci set network.homelab='interface'
uci set network.homelab.proto='static'
uci set network.homelab.device='br-homelab'
uci set network.homelab.ipaddr='172.20.3.254'
uci set network.homelab.netmask='255.255.255.0'
uci set network.homelab.ipv6='0'

# Static route to homelab MetalLB subnet (where services are exposed)
uci add network route
uci set network.@route[-1].interface='homelab'
uci set network.@route[-1].target='172.16.1.0'
uci set network.@route[-1].netmask='255.255.255.0'
uci set network.@route[-1].gateway='172.20.3.253'

uci commit network

# Homelab DHCP
uci set dhcp.homelab='dhcp'
uci set dhcp.homelab.interface='homelab'
uci set dhcp.homelab.start='10'
uci set dhcp.homelab.limit='240'
uci set dhcp.homelab.leasetime='12h'
uci set dhcp.homelab.dhcpv6='disabled'
uci set dhcp.homelab.ra='disabled'
uci add_list dhcp.homelab.dhcp_option='6,172.20.3.254'

# Reserve IP for homelab router
uci add dhcp host
uci set dhcp.@host[-1].name='homelab-router'
uci set dhcp.@host[-1].ip='172.20.3.253'
# Note: Add MAC address after homelab router connects
# uci set dhcp.@host[-1].mac='XX:XX:XX:XX:XX:XX'


uci commit dhcp

# Create homelab firewall zone
uci add firewall zone
uci set firewall.@zone[-1].name='homelab'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].network='homelab'

# Allow Homelab → WAN (Internet access)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='homelab'
uci set firewall.@forwarding[-1].dest='wan'

# Allow LAN → Homelab (access homelab services)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='homelab'

# Allow DNS from homelab to router
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Homelab-DNS'
uci set firewall.@rule[-1].src='homelab'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow DHCP from homelab to router
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Homelab-DHCP'
uci set firewall.@rule[-1].src='homelab'
uci set firewall.@rule[-1].dest_port='67'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow Steam Remote Play (LAN → Homelab)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Steam-RemotePlay'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='homelab'
uci set firewall.@rule[-1].dest_port='27000-27050'
uci set firewall.@rule[-1].proto='udp tcp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow Homelab to router pings for telemetry
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Homelab-ICMP'
uci set firewall.@rule[-1].src='homelab'
uci set firewall.@rule[-1].proto='icmp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow Prometheus from homelab network (172.20.3.0/24)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Prometheus-Homelab'
uci set firewall.@rule[-1].src='homelab'
uci set firewall.@rule[-1].dest_port='9100'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall

# Add .homelab domain records
cat >> /etc/hosts << 'EOF'

# Homelab services (MetalLB IPs - update as needed)
172.16.1.100  gitea.homelab
172.16.1.101  portainer.homelab
172.16.1.102  grafana.homelab
172.16.1.103  prometheus.homelab
172.16.1.104  steam.homelab

# Homelab router
172.20.3.254   main-router.lan
172.16.1.254   router.homelab
EOF

# Configure dnsmasq for .homelab domain
cat >> /etc/dnsmasq.conf << 'EOF'

# Local homelab domain
local=/homelab/
domain=homelab
EOF

# Restart services
/etc/init.d/network restart
sleep 2

/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/avahi-daemon restart