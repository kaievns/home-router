#! /usr/bin sh

# Disable IPv6 in network interfaces
uci set network.lan.ipv6='0'
uci set network.wan.ipv6='0'
uci set network.iot.ipv6='0'

# Delete IPv6 WAN interface if it exists
uci delete network.wan6
uci delete network.@device[0].ipv6 2>/dev/null

# Disable DHCPv6 and router advertisements
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.iot.dhcpv6='disabled'
uci set dhcp.iot.ra='disabled'
uci set dhcp.wan.dhcpv6='disabled' 2>/dev/null

# Remove IPv6 from WAN zone
uci del_list firewall.@zone[1].network='wan6'

# Disable IPv6 firewall rules
uci set firewall.@rule[3].enabled='0'  # Allow-DHCPv6
uci set firewall.@rule[4].enabled='0'  # Allow-MLD
uci set firewall.@rule[5].enabled='0'  # Allow-ICMPv6-Input
uci set firewall.@rule[6].enabled='0'  # Allow-ICMPv6-Forward

# Disable odhcpd (IPv6 DHCP daemon)
/etc/init.d/odhcpd disable
/etc/init.d/odhcpd stop

# Commit everything
uci commit network
uci commit dhcp
uci commit firewall

# disable ipv6 in kernel
cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# Apply immediately
sysctl -p

# restart everything
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart

# Should show no IPv6 addresses
ip -6 addr

# Check listening services (should be no IPv6)
netstat -tlnp | grep -E '(:22|:80|:443)'

# Should NOT see any :::: or ::1 addresses