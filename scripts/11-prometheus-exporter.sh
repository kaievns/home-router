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

# Enable and start
/etc/init.d/prometheus-node-exporter-lua enable
/etc/init.d/prometheus-node-exporter-lua start

mkdir -p /var/prometheus

# Verify
# curl http://127.0.0.1:9100/metrics | grep node_