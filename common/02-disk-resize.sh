#!/bin/sh

opkg update
opkg list-upgradable | cut -f 1 -d ' ' | xargs opkg upgrade
opkg install nano-full


# resizing the root disk to the full eMMC size
opkg install parted losetup resize2fs
wget -U "" -O expand-root.sh "https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0"
. ./expand-root.sh

sh /etc/uci-defaults/70-rootpt-resize
