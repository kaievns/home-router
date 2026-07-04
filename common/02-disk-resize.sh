#!/bin/sh

apk update
# NOTE: apk has NO safe blanket upgrade. The OpenWrt cheat sheet explicitly says
# "DO NOT USE apk upgrade" — incomplete conflicts/deps can brick the box. Do
# firmware+package upgrades via owut / attended-sysupgrade instead (SYSUPGRADE.md).
apk add nano-full


# resizing the root disk to the full eMMC size
apk add parted losetup resize2fs
wget -U "" -O expand-root.sh "https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0"
. ./expand-root.sh

sh /etc/uci-defaults/70-rootpt-resize
