#! /usr/bin sh

wget https://downloads.openwrt.org/releases/24.10.5/targets/rockchip/armv8/openwrt-24.10.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img.gz

gunzip *.img.gz

dd if=openwrt-24.10.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img of=/dev/mmcblk1 bs=1M

sync

poweroff

# pull the card out, boot again

opkg update

opkg list-upgradable | cut -f 1 -d ' ' | xargs opkg upgrade
