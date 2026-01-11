#!/bin/sh

# boot from sd card

wget https://downloads.openwrt.org/releases/24.10.5/targets/rockchip/armv8/openwrt-24.10.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img.gz

gunzip *.img.gz

dd if=openwrt-24.10.5-rockchip-armv8-friendlyarm_nanopi-r5c-ext4-sysupgrade.img of=/dev/mmcblk1 bs=1M

sync

poweroff

# pull the card out, boot again

opkg update
opkg list-upgradable | cut -f 1 -d ' ' | xargs opkg upgrade
opkg install nano-full


# resizing the root disk to the full eMMC size
opkg install parted losetup resize2fs
wget -U "" -O expand-root.sh "https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0"
. ./expand-root.sh

sh /etc/uci-defaults/70-rootpt-resize
