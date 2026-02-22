#!/bin/sh

passwd

# copy key over
# ssh-copy-id root@172.20.1.254

# Check current dropbear (SSH) config
cat /etc/config/dropbear

# Make dropbear to listen only on LAN IP
uci set dropbear.@dropbear[0].Interface='lan'
uci set dropbear.@dropbear[0].GatewayPorts='off'

# you really want those later on
#uci set dropbear.@dropbear[0].RootPasswordAuth='off'  # Disable password login, keys only
#uci set dropbear.@dropbear[0].PasswordAuth='off'      # Disable all password auth

uci commit dropbear
/etc/init.d/dropbear restart


# Verify SSH is blocked from WAN (should already be blocked by default)
uci show firewall | grep -i ssh

