#!/bin/sh

# A set of scripts to fully reset nanopi from an SD card
#
# __NOTE__: hold the the "mod" button before powering up to boot from the SD card
#
# __NOTE__: the sdcard will be on mmcblk0, the eMMC will be either mmcblk1 or mmcblk2, use lsblk to find out

# boot from sd card

cd /tmp

wget https://downloads.openwrt.org/releases/24.10.5/targets/rockchip/armv8/openwrt-24.10.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img.gz
zcat openwrt-24.10.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img.gz | dd of=/dev/mmcblk2 bs=1M status=progress

sync

poweroff

# pull the card out, boot again

ssh root@192.168.1.1 # <- will conflict on default network, so need to change the IP

uci set network.lan.ipaddr='192.168.2.1'
uci commit

reboot

ssh root@192.168.2.1

