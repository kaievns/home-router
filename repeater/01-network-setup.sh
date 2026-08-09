#!/bin/sh

###############################################################
# Wired AP / repeater node setup.
#
# Pure L2 — no DHCP, no DNS, no routing on this box. The home
# router handles all of that; this node just rebroadcasts the
# LAN and IoT SSIDs and provides one wired LAN access port.
#
# Topology:
#   eth1  = uplink trunk to home router carrying:
#             untagged → LAN (172.20.1.0/24)
#             VLAN 20  → IoT (172.20.2.0/24)
#   eth0  = LAN access port (untagged LAN only — IoT/homelab
#             are NOT exposed here)
#   wifi  = 5GHz LAN SSID  -> br-lan
#           2.4GHz IoT SSID -> br-iot
###############################################################

##############################################################
# MAC uniqueness check — RUN THIS FIRST, believe the warning.
#
# /etc/board.json lives in /etc, so a sysupgrade backup carries it (and
# the MAC addresses it records) to whatever box you restore onto. Restore
# one node's backup onto DIFFERENT hardware and you have cloned its MACs.
# Two nodes claiming one MAC on the same L2 segment looks like this:
#
#   br-lan: received packet on eth1 with own address as source address
#
# ...several times a second, with ~50% packet loss, SSH sessions dying
# mid-command, and wifi clients that associate then go nowhere. It reads
# like failing hardware or a bridging loop; it is neither.
#
# The R5C derives its MACs from the eMMC CID, which IS unique per board,
# so we can just ask what this hardware *should* be using.
. /lib/functions/system.sh 2>/dev/null
HW_MAC=$(macaddr_generate_from_mmc_cid mmcblk* 2>/dev/null)
CUR_MAC=$(cat /sys/class/net/eth1/address 2>/dev/null)
if [ -n "$HW_MAC" ] && [ -n "$CUR_MAC" ] && [ "$HW_MAC" != "$CUR_MAC" ]; then
    echo "############################################################"
    echo "WARNING: eth1 is using $CUR_MAC but this board derives $HW_MAC."
    echo "This node was almost certainly restored from another box's"
    echo "backup and is now a MAC twin of it. Pick unused addresses and:"
    echo "  uci set network.<eth0 section>.macaddr='<new>'   # e.g. ...:61"
    echo "  uci set network.<eth1 section>.macaddr='<new>'   # e.g. ...:60"
    echo "  sed -i 's/<old>/<new>/g' /etc/board.json   # else it comes back"
    echo "  /etc/init.d/network restart"
    echo "############################################################"
fi

# Manageable from main LAN. Default OpenWrt config puts this on
# 192.168.x.x; change here so we land on the real LAN subnet
# right away.
uci set network.lan.proto='static'
uci set network.lan.ipaddr='172.20.1.252'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='172.20.1.254'
uci set network.lan.dns='172.20.1.254'
uci set network.lan.ipv6='0'

##############################################################
# Replace the default anonymous br-lan with a named one that
# bridges both the uplink (eth1, untagged LAN) and the wired
# access port (eth0).

i=0
while uci -q get network.@device[$i] >/dev/null 2>&1; do
    name=$(uci -q get network.@device[$i].name 2>/dev/null)
    if [ "$name" = "br-lan" ]; then
        uci delete network.@device[$i]
        break
    fi
    i=$((i+1))
done

uci set network.br_lan='device'
uci set network.br_lan.type='bridge'
uci set network.br_lan.name='br-lan'
uci add_list network.br_lan.ports='eth1'
uci add_list network.br_lan.ports='eth0'
uci set network.lan.device='br-lan'

# This node is NOT a DHCP server — main router does that.
uci set dhcp.lan.ignore='1'

##############################################################
# Drop the stock `wan` interface.
#
# Default config puts wan on eth1 with proto='dhcp', but here eth1 is a
# br-lan PORT. Leaving it means udhcpc sits there broadcasting DISCOVERs
# onto the LAN forever, and it can pick up a lease that fights the static
# address set above. The wan firewall zone goes too — it carries masq='1'
# and an AP has nothing to NAT.
uci -q delete network.wan
uci -q delete network.wan6
uci -q delete dhcp.wan

i=0
while uci -q get firewall.@zone[$i] >/dev/null 2>&1; do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ]; then
        uci delete firewall.@zone[$i]; break
    fi
    i=$((i+1))
done

i=0
while uci -q get firewall.@forwarding[$i] >/dev/null 2>&1; do
    if [ "$(uci -q get firewall.@forwarding[$i].dest)" = "wan" ]; then
        uci delete firewall.@forwarding[$i]; break
    fi
    i=$((i+1))
done

##############################################################
# Let this node resolve .homelab names.
#
# Switching off the DHCP server above does NOT stop dnsmasq — it still
# runs as this box's caching resolver. Its rebind protection discards any
# answer mapping a non-local name to an RFC1918 address, which is exactly
# what every .homelab record is, so lookups die with:
#
#   dnsmasq: possible DNS-rebind attack detected: loki.homelab
#
# The visible symptom is log shipping failing with http=000 while plain
# internet DNS works fine.
#
# Both MUST be add_list. `uci set` writes a plain option and the dnsmasq
# init script reads these with config_list_foreach, so a plain option is
# ignored silently — the config looks right and does nothing.
uci -q delete dhcp.@dnsmasq[0].server
uci -q delete dhcp.@dnsmasq[0].rebind_domain
uci add_list dhcp.@dnsmasq[0].server='/homelab/172.20.1.254'
uci add_list dhcp.@dnsmasq[0].rebind_domain='homelab'

##############################################################
# IoT extension bridge — VLAN 20 lifted off the uplink trunk.
# eth0 is deliberately NOT a member, so wired clients on the
# LAN access port cannot reach IoT.

uci set network.eth1_v20='device'
uci set network.eth1_v20.type='8021q'
uci set network.eth1_v20.ifname='eth1'
uci set network.eth1_v20.vid='20'
uci set network.eth1_v20.name='eth1.20'

uci set network.br_iot='device'
uci set network.br_iot.type='bridge'
uci set network.br_iot.name='br-iot'
uci add_list network.br_iot.ports='eth1.20'

uci set network.iot_ext='interface'
uci set network.iot_ext.proto='none'
uci set network.iot_ext.device='br-iot'

uci commit network
uci commit dhcp

##############################################################
# Firewall zones — security is enforced upstream at the home
# router. Just need zones so OpenWrt doesn't drop forwarded L2
# traffic. The default 'lan' zone already covers br-lan with
# input=ACCEPT, which is what we want for SSH manageability.

uci add firewall zone
uci set firewall.@zone[-1].name='iot_ext'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].network='iot_ext'

uci commit firewall

# Apply
/etc/init.d/network restart
sleep 2
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart

##############################################################
# STILL TO DO BY HAND on a new node — none of it is in this repo,
# and every one of them fails quietly rather than loudly:
#
#  * /etc/local-secrets ships with CHANGE_ME placeholders. Fill in
#    S3_KEY, S3_SECRET, BACKUP_PASSPHRASE and LOKI_AUTH_USERNAME /
#    LOKI_AUTH_PASSWORD by copying them off an existing node:
#
#      ssh root@<existing> 'grep -E "^(S3_KEY|S3_SECRET|BACKUP_PASSPHRASE|LOKI_AUTH_)" /etc/local-secrets' \
#        | ssh root@<new> 'cat >> /etc/local-secrets'
#
#    Reuse the existing BACKUP_PASSPHRASE rather than generating a fresh
#    one — a per-node passphrase you haven't stored off-device means
#    that node's backups are unrecoverable, which you find out at
#    exactly the wrong moment. Without the LOKI_* pair the shipper runs
#    happily and logs "pushing without basic auth", then 401s forever.
#
#  * Schedule the backup (common/10 installs the script but not the cron).
#    Offset it from the other nodes so the S3 pushes don't collide:
#      (crontab -l 2>/dev/null; echo "45 4 * * * /usr/bin/router-backup.sh >/dev/null 2>&1") | crontab -
#
#  * Verify both, because both exit 0 while doing nothing useful:
#      /usr/bin/router-backup.sh; logread | grep backup | tail -2
#      logread | grep loki-shipper | tail -3
