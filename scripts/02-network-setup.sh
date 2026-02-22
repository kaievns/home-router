#!/bin/sh


# Set the router IP to 172.20.1.254 (end of the range)
uci set network.lan.ipaddr='172.20.1.254'
#uci set network.lan.ipaddr='172.16.1.254' # for homelab router

# Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

