#!/bin/sh

###################################################################
# My wifi is set as 2.4GHz for IoT devices and 5GHz for everything else. Adjust as needed.
# The 5GHz network is set to channel 149 which is usually less congested and
###################################################################

# Set the router IP to 172.20.1.254 (end of the range)
uci set network.lan.ipaddr='172.20.1.254'

# Set the netmask for /24 network
uci set network.lan.netmask='255.255.255.0'

/etc/init.d/network restart
/etc/init.d/dnsmasq restart

# Configure uhttpd (web server) to listen only on LAN
uci set uhttpd.main.listen_http='172.20.1.254:80'
uci set uhttpd.main.listen_https='172.20.1.254:443'

uci commit uhttpd
/etc/init.d/uhttpd restart


# Configure radio1 (5GHz) - main network
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.txpower='30' # 3dBm antennas
uci set wireless.default_radio1.ssid='HomeRouter'
uci set wireless.default_radio1.encryption='sae'
uci set wireless.default_radio1.key='YourStrongPassword123'
uci set wireless.default_radio1.network='lan'

# Configure radio0 (2.4GHz) - IoT network
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='AU'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.txpower='20'
uci set wireless.default_radio0.ssid='HomeRouter_IoT'
uci set wireless.default_radio0.encryption='sae'
uci set wireless.default_radio0.key='YourStrongPassword123'
uci set wireless.default_radio0.network='iot'

uci commit wireless
wifi
