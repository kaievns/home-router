#!/bin/sh

HOMELAB_SSID="Name_Homelab"
HOMELAB_PASSWORD="YourHomelabPasswordHere"


# Homelab backhaul network
uci set network.homelab='interface'
uci set network.homelab.proto='static'
uci set network.homelab.ipaddr='172.20.3.254'
uci set network.homelab.netmask='255.255.255.0'
uci set network.homelab.ipv6='0'

# Static route to homelab MetalLB subnet (where services are exposed)
uci add network route
uci set network.@route[-1].interface='homelab'
uci set network.@route[-1].target='172.16.1.0'
uci set network.@route[-1].netmask='255.255.255.0'
uci set network.@route[-1].gateway='172.20.3.254'

uci commit network

# Homelab DHCP
uci set dhcp.homelab='dhcp'
uci set dhcp.homelab.interface='homelab'
uci set dhcp.homelab.start='10'
uci set dhcp.homelab.limit='240'
uci set dhcp.homelab.leasetime='12h'
uci set dhcp.homelab.dhcpv6='disabled'
uci set dhcp.homelab.ra='disabled'

# Reserve IP for homelab router
uci add dhcp host
uci set dhcp.@host[-1].name='homelab-router'
uci set dhcp.@host[-1].ip='172.20.3.253'
# Note: Add MAC address after homelab router connects
# uci set dhcp.@host[-1].mac='XX:XX:XX:XX:XX:XX'

uci commit dhcp


# Add second 5GHz SSID for homelab backhaul on radio1
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio1'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid="$HOMELAB_SSID"
uci set wireless.@wifi-iface[-1].encryption='sae'
uci set wireless.@wifi-iface[-1].key="$HOMELAB_PASSWORD"
uci set wireless.@wifi-iface[-1].network='homelab'
uci set wireless.@wifi-iface[-1].isolate='1'
uci set wireless.@wifi-iface[-1].hidden='1'

uci commit wireless

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
172.20.3.254   homelab-router.local
172.16.1.254   router.homelab
EOF

# Configure dnsmasq for .homelab domain
cat >> /etc/dnsmasq.conf << 'EOF'

# Local homelab domain
local=/homelab/
domain=homelab
EOF

# Update avahi configuration to include homelab interface
cat > /etc/avahi/avahi-daemon.conf << 'EOF'
[server]
use-ipv4=yes
use-ipv6=no
enable-dbus=yes
allow-interfaces=br-lan,br-iot,br-homelab
deny-interfaces=eth1

[reflector]
enable-reflector=yes
reflect-ipv=yes
EOF

# Restart avahi if already running
/etc/init.d/avahi-daemon restart

# Restart services
/etc/init.d/network restart
sleep 2

/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart

wifi