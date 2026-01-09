#! /usr/bin sh

# copy key over
# ssh-copy-id root@172.20.1.254

passwd

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

# Explicitly block SSH from IoT zone
uci add firewall rule
uci set firewall.@rule[-1].name='Block-IoT-SSH'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='REJECT'

uci commit firewall
/etc/init.d/firewall restart

# Configure uhttpd (web server) to listen only on LAN
uci set uhttpd.main.listen_http='172.20.1.254:80'
uci set uhttpd.main.listen_https='172.20.1.254:443'

uci commit uhttpd
/etc/init.d/uhttpd restart
