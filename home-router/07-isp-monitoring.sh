#!/bin/sh

# ISP Monitoring Setup for OpenWrt
# Uses prometheus-node-exporter-lua-textfile
#
# runs ping/latency/packet loss checks every 15 seconds
# runs WAN/Public IP check every 1 minute
# runs speedtest every 30 mins
#

set -e

opkg update
opkg install speedtest-go bc curl jq

SCRIPTS_DIR="/usr/bin"

##############################################################
# Packet Loss & Latency
##############################################################
cat > "$SCRIPTS_DIR/packet-loss.sh" << 'EOFPACKET'
#!/bin/sh
TEXTFILE="/var/prometheus/isp-packetloss.prom"
# Targets: Cloudflare, Google, Quad9
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"

# Initialize file
cat > "$TEXTFILE.$$" << EOF
# HELP isp_packet_loss_percent Packet loss percentage
# TYPE isp_packet_loss_percent gauge
# HELP isp_latency_ms Average round-trip latency
# TYPE isp_latency_ms gauge
EOF

for TARGET in $TARGETS; do
  # Ping 5 times. Capture output.
  OUTPUT=$(ping -c 5 -W 1 "$TARGET" 2>&1)
  
  # Parse Packet Loss (Busybox format: "0% packet loss")
  LOSS=$(echo "$OUTPUT" | grep -oE '[0-9]+% packet loss' | awk '{print $1}' | tr -d '%')
  [ -z "$LOSS" ] && LOSS=100

  # Parse Latency (Busybox format: "round-trip min/avg/max = 1.1/2.2/3.3 ms")
  LATENCY=$(echo "$OUTPUT" | awk -F'/' '/round-trip/ {print $4}')
  [ -z "$LATENCY" ] && LATENCY=0

  echo "isp_packet_loss_percent{target=\"$TARGET\"} $LOSS" >> "$TEXTFILE.$$"
  echo "isp_latency_ms{target=\"$TARGET\"} $LATENCY" >> "$TEXTFILE.$$"
done

# Timestamp
echo "isp_packet_loss_last_check_timestamp $(date +%s)" >> "$TEXTFILE.$$"
mv "$TEXTFILE.$$" "$TEXTFILE"
EOFPACKET

chmod +x "$SCRIPTS_DIR/packet-loss.sh"

##############################################################
# Speedtest
##############################################################
cat > "$SCRIPTS_DIR/speedtest.sh" << 'EOFSPEED'
#!/bin/sh
TEXTFILE="/var/prometheus/isp-speedtest.prom"
LOCK_FILE="/tmp/speedtest.lock"

if [ -e "$LOCK_FILE" ]; then
  OLDPID=$(cat "$LOCK_FILE")
  if kill -0 "$OLDPID" 2>/dev/null; then
    exit 0
  else
    rm -f "$LOCK_FILE"
  fi
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

RESULT=$(speedtest-go --saving-mode --json 2>&1)

# Parsing logic
DOWNLOAD=$(echo "$RESULT" | jq -r '.servers[0].dl_speed // 0' | awk '{printf "%.2f", $1/125000}')
UPLOAD=$(echo "$RESULT" | jq -r '.servers[0].ul_speed // 0' | awk '{printf "%.2f", $1/125000}')
LATENCY=$(echo "$RESULT" | jq -r '.servers[0].latency // 0' | awk '{printf "%.3f", $1/1000000}')
JITTER=$(echo "$RESULT" | jq -r '.servers[0].jitter // 0' | awk '{printf "%.3f", $1/1000000}')

cat > "$TEXTFILE.$$" << EOF
# HELP isp_speedtest_download_mbps Download speed in Mbps
# TYPE isp_speedtest_download_mbps gauge
isp_speedtest_download_mbps $DOWNLOAD
# HELP isp_speedtest_upload_mbps Upload speed in Mbps
# TYPE isp_speedtest_upload_mbps gauge
isp_speedtest_upload_mbps $UPLOAD
# HELP isp_speedtest_latency_ms Latency in ms
# TYPE isp_speedtest_latency_ms gauge
isp_speedtest_latency_ms $LATENCY
# HELP isp_speedtest_jitter_ms Jitter in ms
# TYPE isp_speedtest_jitter_ms gauge
isp_speedtest_jitter_ms $JITTER
isp_speedtest_last_run_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFSPEED

chmod +x "$SCRIPTS_DIR/speedtest.sh"

##############################################################
# Get Public IP
##############################################################
cat > /usr/bin/wanip.sh << 'EOFWAN'
#!/bin/sh
# WAN and Public IP tracking

TEXTFILE="/var/prometheus/isp-wanip.prom"

# Get WAN IP from OpenWrt internal functions
. /lib/functions/network.sh
network_find_wan NET_IF
network_get_ipaddr WAN_IP "${NET_IF}"

# Get Public IP (Try ipify first, failover to ifconfig.me, else unknown)
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me/ip || echo "unknown")

# Write metrics into a temporary file first, then move atomically to prevent half-written reads
cat > "$TEXTFILE.tmp" << EOF
# HELP isp_wan_ip_info WAN IP address assigned by ISP
# TYPE isp_wan_ip_info gauge
isp_wan_ip_info{wan_ip="$WAN_IP",public_ip="$PUBLIC_IP"} 1

# HELP isp_wan_ip_last_check_timestamp Last WAN IP check
# TYPE isp_wan_ip_last_check_timestamp gauge
isp_wan_ip_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.tmp" "$TEXTFILE"
EOFWAN

chmod +x "$SCRIPTS_DIR/wanip.sh"

# Create cron entries
cat >> /etc/crontabs/root << 'EOFCRON'

# ISP Monitoring
*/30 * * * * /usr/bin/speedtest.sh
*/1 * * * * /usr/bin/wanip.sh

# Every 15 seconds
* * * * * /usr/bin/packet-loss.sh
* * * * * sleep 15; /usr/bin/packet-loss.sh
* * * * * sleep 30; /usr/bin/packet-loss.sh
* * * * * sleep 45; /usr/bin/packet-loss.sh
EOFCRON

/etc/init.d/cron restart

# Run initial collection
# /usr/bin/speedtest.sh &
# /usr/bin/packet-loss.sh &
# /usr/bin/wanip.sh &
