#!/bin/sh


# Set the router IP to 172.20.1.254 (end of the range)
uci set network.lan.ipaddr='172.20.1.254'
uci set network.lan.netmask='255.255.255.0'

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

# Configure uhttpd (web server) to listen only on LAN
uci set uhttpd.main.listen_http='172.20.1.254:80'
uci set uhttpd.main.listen_https='172.20.1.254:443'

uci commit uhttpd
/etc/init.d/uhttpd restart

# adds service discovery for the IoT/Lab -> Lan

# Install avahi mDNS reflector
opkg update
opkg install avahi-daemon avahi-dbus-daemon

# Configure avahi to reflect between lan and iot/lab
# for service discovery across subnets, but not to reflect to WAN (eth1)
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

# Enable and start
/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon start