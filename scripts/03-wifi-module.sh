#!/bin/sh

opkg update

# checking if the module is connected
opkg install pciutils
lspci -nn | grep -i network
# 0000:01:00.0 Network controller [0280]: MEDIATEK Corp. Device [14c3:7906]

# installing the drivers
opkg install kmod-mt7916-firmware
opkg install iw wireless-tools

reboot

# ssh back in

iw dev
dmesg | grep mt76
# [    8.664143] mt7915e 0000:01:00.0: registering led 'mt76-phy0'
# [    8.698012] mt7915e 0000:01:00.0: registering led 'mt76-phy1'
ls /sys/class/ieee80211/
# phy0  phy1
# ^--- you should see the two radios!

# Check capabilities of each radio
iw phy phy0 info | grep -A 10 "Frequencies"
# Frequencies:
# 	* 2412.0 MHz [1] (17.0 dBm)
# 	* 2417.0 MHz [2] (17.0 dBm)
# 	* 2422.0 MHz [3] (17.0 dBm)
# 	* 2427.0 MHz [4] (17.0 dBm)
# 	* 2432.0 MHz [5] (17.0 dBm)
# 	* 2437.0 MHz [6] (17.0 dBm)
# 	* 2442.0 MHz [7] (17.0 dBm)
# 	* 2447.0 MHz [8] (17.0 dBm)
# 	* 2452.0 MHz [9] (17.0 dBm)
# 	* 2457.0 MHz [10] (17.0 dBm)
iw phy phy1 info | grep -A 10 "Frequencies"
# Frequencies:
# 	* 5180.0 MHz [36] (20.0 dBm)
# 	* 5200.0 MHz [40] (20.0 dBm)
# 	* 5220.0 MHz [44] (20.0 dBm)
# 	* 5240.0 MHz [48] (20.0 dBm)
# 	* 5260.0 MHz [52] (20.0 dBm) (no IR, radar detection)
# 	* 5280.0 MHz [56] (20.0 dBm) (no IR, radar detection)
# 	* 5300.0 MHz [60] (20.0 dBm) (no IR, radar detection)
# 	* 5320.0 MHz [64] (20.0 dBm) (no IR, radar detection)
# 	* 5500.0 MHz [100] (20.0 dBm) (no IR, radar detection)
# 	* 5520.0 MHz [104] (20.0 dBm) (no IR, radar detection)

# getting the wifi config
wifi config
cat /etc/config/wireless

# config wifi-device 'radio0'
# 	option type 'mac80211'
# 	option path '3c0000000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0'
# 	option band '2g'
# 	option channel '1'
# 	option htmode 'HE20'
# 	option disabled '1'

# config wifi-iface 'default_radio0'
# 	option device 'radio0'
# 	option network 'lan'
# 	option mode 'ap'
# 	option ssid 'OpenWrt'
# 	option encryption 'none'

# config wifi-device 'radio1'
# 	option type 'mac80211'
# 	option path '3c0000000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0+1'
# 	option band '5g'
# 	option channel '36'
# 	option htmode 'HE80'
# 	option disabled '1'

# config wifi-iface 'default_radio1'
# 	option device 'radio1'
# 	option network 'lan'
# 	option mode 'ap'
# 	option ssid 'OpenWrt'
# 	option encryption 'none'

# Configure radio1 (5GHz) - main network
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='AU'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.txpower='20' # 16dBm antennas
uci set wireless.default_radio1.ssid='Name'
uci set wireless.default_radio1.encryption='sae'
uci set wireless.default_radio1.key='YourStrongPassword123'
uci set wireless.default_radio1.network='lan'

# Configure radio0 (2.4GHz) - IoT network
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='AU'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.txpower='20'
uci set wireless.default_radio0.ssid='Name_IoT'
uci set wireless.default_radio0.encryption='sae'
uci set wireless.default_radio0.key='YourStrongPassword123'
uci set wireless.default_radio0.network='iot'

uci commit wireless
wifi