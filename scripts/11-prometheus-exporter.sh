#!/bin/sh

#
# Setting up the prometheus exporter
#

opkg update
opkg install \
  prometheus-node-exporter-lua \
  prometheus-node-exporter-lua-openwrt \
  prometheus-node-exporter-lua-nat_traffic \
  prometheus-node-exporter-lua-netstat \
  prometheus-node-exporter-lua-wifi \
  prometheus-node-exporter-lua-wifi_stations \
  prometheus-node-exporter-lua-thermal \
  prometheus-node-exporter-lua-hwmon \
  prometheus-node-exporter-lua-uci_dhcp_host \
  prometheus-node-exporter-lua-textfile \
  curl \
  bc

# make sure /var is symlinked to /tmp so we didn't write to eMMC
mkdir -p /var/prometheus

# Pointing the textfile collector to the new location
uci set prometheus-node-exporter-lua.main.textfile_dir='/var/prometheus'
uci commit prometheus-node-exporter-lua

# Enable and start
/etc/init.d/prometheus-node-exporter-lua enable
/etc/init.d/prometheus-node-exporter-lua start

# Ensure tmpfs dir is recreated on boot
if ! grep -q "mkdir -p /tmp/prometheus" /etc/rc.local; then
  sed -i '/^exit 0/i mkdir -p /tmp/prometheus' /etc/rc.local
fi

# Verify
# curl http://127.0.0.1:9100/metrics | grep node_