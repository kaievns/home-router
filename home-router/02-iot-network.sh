#!/bin/sh

###############################################################
# This is a setup for IoT network with a separate subnet and 
# firewall rules. It can only access the Internet
#
# __NOTE:__ this network is bridged to VLAN 20 on the trunk
# to make it available across two routers on the network
################################################################

# VLAN 20 device — carries IoT traffic
uci set network.eth0_v20='device'
uci set network.eth0_v20.type='8021q'
uci set network.eth0_v20.ifname='eth0'
uci set network.eth0_v20.vid='20'
uci set network.eth0_v20.name='eth0.20'

# Ensure IoT has an explicit bridge device with the trunk VLAN port.
# When WiFi interfaces specify network='iot', OpenWrt adds them to this bridge.
uci set network.br_iot='device'
uci set network.br_iot.type='bridge'
uci set network.br_iot.name='br-iot'
uci add_list network.br_iot.ports='eth0.20'

# Create IoT interface with IP 172.20.2.254 (end of range)
uci set network.iot='interface'
uci set network.iot.proto='static'
uci set network.iot.device='br-iot'
uci set network.iot.ipaddr='172.20.2.254'
uci set network.iot.netmask='255.255.255.0'
uci set network.iot.ipv6='0'

# Configure DHCP for IoT network
uci set dhcp.iot='dhcp'
uci set dhcp.iot.interface='iot'
uci set dhcp.iot.start='1'
uci set dhcp.iot.limit='253'
uci set dhcp.iot.leasetime='12h'
uci set dhcp.iot.dhcpv6='disabled'
uci set dhcp.iot.ra='disabled'
uci add_list dhcp.iot.dhcp_option='6,172.20.2.254'

uci commit network
uci commit dhcp

# Create IoT firewall zone
uci add firewall zone
uci set firewall.@zone[-1].name='iot'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].network='iot'

# Allow IoT → WAN (Internet access)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='iot'
uci set firewall.@forwarding[-1].dest='wan'

# Allow LAN → IoT (main network can access IoT devices)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='iot'

# Allow DNS and DHCP from IoT to router
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-DNS'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-DHCP'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='67'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow mDNS to reach avahi reflector on the router.
# Without this, IoT-side service announcements (AirPlay/AirPrint/Chromecast)
# never reach avahi and discovery from LAN silently fails.
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-mDNS'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='5353'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow AirPlay from LAN devices to TVs on the IoT network.
#
# Symptom without this: the TV pairs, the phone shows "connecting", then
# "unable to connect" ~10s later. Discovery (mDNS reflector) and the whole
# phone->TV plane work fine — control on TCP 7000, the mirror stream, audio —
# because those are lan->iot and the blanket forwarding covers them. What
# fails is the ONE flow the receiver originates back toward the sender: a new
# iot->lan UDP flow with no conntrack state, which forward=REJECT drops. With
# no timing/media channel the sender's watchdog tears the session down.
#
# WHICH ports depends on the receiver — verify with a capture, don't guess:
#   tcpdump -ni br-iot -tttt '(host <TV_IP>) and net 172.20.1.0/24'
# then cast, and look for a UDP packet FROM the TV toward the phone.
#
#   * LG webOS (OLED B8 series, verified 2026-08): ephemeral->ephemeral UDP,
#     e.g. TV:39631 -> phone:52792. PTP 319/320 is NEVER used — a 319/320-only
#     rule sits at 0 packets and the cast still fails. The ephemeral rule is
#     the load-bearing one; a single 60-byte packet is all it takes.
#   * Apple TV / HomePod: AirPlay 2 PTP on UDP 319/320 (receiver is
#     grandmaster). Harmless to keep both rules — each covers a different
#     receiver type.
#
# Scope BOTH rules to the TV IPs and give the TVs DHCP reservations first, so
# the opening can't drift to another IoT device. dest='lan' already binds to
# br-lan; no dest_ip needed. UDP only — no TCP return rule is required.
#
# Tradeoff on the ephemeral rule: it lets those specific TVs send UDP to any
# high port on any LAN host. Contained by src_ip + UDP-only + no low ports;
# LAN hosts rarely listen on high UDP outside an active session. Tighten with
# dest_ip=<PHONE_IP> if you want, but that's a rule per Apple device.
#
# uci set firewall.airplay_ptp='rule'
# uci set firewall.airplay_ptp.name='Allow-IoT-AirPlay-PTP'
# uci set firewall.airplay_ptp.src='iot'
# uci set firewall.airplay_ptp.dest='lan'
# uci add_list firewall.airplay_ptp.src_ip='<TV1_IP>'
# uci add_list firewall.airplay_ptp.src_ip='<TV2_IP>'
# uci set firewall.airplay_ptp.proto='udp'
# uci set firewall.airplay_ptp.dest_port='319-320'
# uci set firewall.airplay_ptp.target='ACCEPT'
#
# uci set firewall.airplay_rtcp='rule'
# uci set firewall.airplay_rtcp.name='Allow-IoT-AirPlay-RTCP'
# uci set firewall.airplay_rtcp.src='iot'
# uci set firewall.airplay_rtcp.dest='lan'
# uci add_list firewall.airplay_rtcp.src_ip='<TV1_IP>'
# uci add_list firewall.airplay_rtcp.src_ip='<TV2_IP>'
# uci set firewall.airplay_rtcp.proto='udp'
# uci set firewall.airplay_rtcp.dest_port='49152-65535'
# uci set firewall.airplay_rtcp.target='ACCEPT'

# Explicitly block SSH from IoT zone
uci add firewall rule
uci set firewall.@rule[-1].name='Block-IoT-SSH'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='REJECT'

uci commit firewall

# Restart everything
/etc/init.d/network restart
/etc/init.d/firewall restart
