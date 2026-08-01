#!/bin/sh

# A set of scripts to fully reset nanopi from an SD card
#
# __NOTE__: hold the the "mod" button before powering up to boot from the SD card
#
# __NOTE__: the sdcard will be on mmcblk0, the eMMC will be either mmcblk1 or mmcblk2, use lsblk to find out

# boot from sd card

cd /tmp

wget https://downloads.openwrt.org/releases/25.12.5/targets/rockchip/armv8/openwrt-25.12.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img.gz
zcat openwrt-25.12.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img.gz | dd of=/dev/mmcblk1 bs=1M

sync

poweroff

# pull the card out, boot again, remove 192.168.1.1 from known hosts

ssh root@192.168.1.1 

# if conflicts on default network, so need to change the IP
# uci set network.lan.ipaddr='192.168.2.1'
# uci commit
# reboot
# ssh root@192.168.2.1

