#!/bin/sh

# adds service discovery for the IoT -> Lan

# Install avahi mDNS reflector
opkg update
opkg install avahi-daemon avahi-dbus-daemon

# Configure avahi to reflect between lan and iot
cat > /etc/avahi/avahi-daemon.conf << 'EOF'
[server]
use-ipv4=yes
use-ipv6=no
enable-dbus=yes
allow-interfaces=br-lan,br-iot
deny-interfaces=eth1

[reflector]
enable-reflector=yes
reflect-ipv=yes
EOF

# Enable and start
/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon start