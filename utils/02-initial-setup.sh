#!/usr/bin sh

# 1. Update package lists
opkg update

# 2. Upgrade installed packages
opkg list-upgradable | cut -f 1 -d ' ' | xargs opkg upgrade

# 3. Set the router IP to 172.20.1.254 (end of the range)
uci set network.lan.ipaddr='172.20.1.254'

# 4. Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

# 5. Configure DHCP range (172.20.1.1 to 172.20.1.253)
uci set dhcp.lan.start='1'
uci set dhcp.lan.limit='253'

# 6. Set DHCP lease time (optional, 12 hours)
uci set dhcp.lan.leasetime='12h'

# 7. Commit the changes
uci commit

# 8. Restart network services
/etc/init.d/network restart
/etc/init.d/dnsmasq restart

