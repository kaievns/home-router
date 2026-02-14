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

TEXTFILE_DIR="/var/prometheus"
SCRIPTS_DIR="/usr/bin"

mkdir -p "$TEXTFILE_DIR"

##############################################################
# speed testing
##############################################################
cat > "$SCRIPTS_DIR/speedtest.sh" << 'EOFSPEED'
#!/bin/sh
# Speedtest script - writes Prometheus metrics

TEXTFILE="/var/prometheus/speedtest.prom"
LOCK_FILE="/tmp/speedtest.lock"

# Lock check
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

# Run speedtest with JSON output
RESULT=$(speedtest-go --json 2>&1)

# Speeds are in bytes/sec, convert to Mbps (divide by 125000)
# Latency/jitter are in nanoseconds, convert to ms (divide by 1000000)
DOWNLOAD=$(echo "$RESULT" | jq -r '.servers[0].dl_speed // 0' | awk '{printf "%.2f", $1/125000}')
UPLOAD=$(echo "$RESULT" | jq -r '.servers[0].ul_speed // 0' | awk '{printf "%.2f", $1/125000}')
LATENCY=$(echo "$RESULT" | jq -r '.servers[0].latency // 0' | awk '{printf "%.3f", $1/1000000}')
JITTER=$(echo "$RESULT" | jq -r '.servers[0].jitter // 0' | awk '{printf "%.3f", $1/1000000}')

# Calculate packet loss percentage
SENT=$(echo "$RESULT" | jq -r '.servers[0].packet_loss.sent // 0')
RECEIVED=$(echo "$RESULT" | jq -r '.servers[0].packet_loss.max // 0')
if [ "$SENT" -gt 0 ]; then
  PACKET_LOSS=$(echo "scale=2; (($SENT - $RECEIVED) * 100) / $SENT" | bc)
else
  PACKET_LOSS="0"
fi

# Write Prometheus metrics
cat > "$TEXTFILE.$$" << EOF
# HELP isp_speedtest_download_mbps Download speed in Mbps
# TYPE isp_speedtest_download_mbps gauge
isp_speedtest_download_mbps $DOWNLOAD

# HELP isp_speedtest_upload_mbps Upload speed in Mbps
# TYPE isp_speedtest_upload_mbps gauge
isp_speedtest_upload_mbps $UPLOAD

# HELP isp_speedtest_latency_ms Latency in milliseconds
# TYPE isp_speedtest_latency_ms gauge
isp_speedtest_latency_ms $LATENCY

# HELP isp_speedtest_jitter_ms Jitter in milliseconds
# TYPE isp_speedtest_jitter_ms gauge
isp_speedtest_jitter_ms $JITTER

# HELP isp_speedtest_packet_loss_percent Packet loss percentage
# TYPE isp_speedtest_packet_loss_percent gauge
isp_speedtest_packet_loss_percent $PACKET_LOSS

# HELP isp_speedtest_last_run_timestamp Last successful speedtest run
# TYPE isp_speedtest_last_run_timestamp gauge
isp_speedtest_last_run_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFSPEED

chmod +x "$SCRIPTS_DIR/speedtest.sh"


##############################################################
# Packet loss tracking
##############################################################
cat > "$SCRIPTS_DIR/packet-loss.sh" << 'EOFPACKET'
#!/bin/sh
# Packet loss monitoring - multiple targets

TEXTFILE="/var/prometheus/packetloss.prom"

LOCK_FILE="/tmp/packetloss.lock"

# Prevent overlapping runs
if [ -e "$LOCK_FILE" ]; then
  OLDPID=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# Targets to monitor
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"

# Start metrics file
cat > "$TEXTFILE.tmp" << EOF
# HELP isp_packet_loss_percent Packet loss percentage to target
# TYPE isp_packet_loss_percent gauge
EOF

# Ping each target
for TARGET in $TARGETS; do
  # Ping 10 times, 1 second timeout
  RESULT=$(ping -c 10 -W 1 "$TARGET" 2>&1)
  
  if echo "$RESULT" | grep -q "packet loss"; then
    LOSS=$(echo "$RESULT" | grep "packet loss" | awk -F',' '{print $3}' | awk '{print $1}' | tr -d '%')
    
    # Extract latency stats if available
    if echo "$RESULT" | grep -q "min/avg/max"; then
      LATENCY=$(echo "$RESULT" | grep "min/avg/max" | cut -d= -f2 | cut -d/ -f2)
    else
      LATENCY="0"
    fi
  else
    LOSS="100"
    LATENCY="0"
  fi
  
  # Write metrics
  echo "isp_packet_loss_percent{target=\"$TARGET\"} $LOSS" >> "$TEXTFILE.tmp"
  echo "isp_latency_ms{target=\"$TARGET\"} $LATENCY" >> "$TEXTFILE.tmp"
done

# Add timestamp
cat >> "$TEXTFILE.tmp" << EOF

# HELP isp_packet_loss_last_check_timestamp Last packet loss check
# TYPE isp_packet_loss_last_check_timestamp gauge
isp_packet_loss_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.tmp" "$TEXTFILE"
EOFPACKET

chmod +x "$SCRIPTS_DIR/packet-loss.sh"


##############################################################
# Public IP tracking
##############################################################
cat > "$SCRIPTS_DIR/wanip.sh" << 'EOFWAN'
#!/bin/sh
# WAN and Public IP tracking

TEXTFILE="/var/prometheus/wanip.prom"

# Get WAN IP from router interface
. /lib/functions/network.sh
network_find_wan NET_IF
network_get_ipaddr WAN_IP "${NET_IF}"

# Get public IP from external service
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")

# Write metrics
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
