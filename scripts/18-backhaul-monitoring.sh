#!/bin/sh

# Backhaul Monitoring Setup - Homelab Router

TEXTFILE_DIR="/var/prometheus"
SCRIPTS_DIR="/usr/bin"
MAIN_ROUTER="172.20.3.254"
WIFI_INTERFACE="phy1-sta0"

# 1. Create backhaul-latency.sh
cat > "$SCRIPTS_DIR/backhaul-latency.sh" << 'EOFLATENCY'
#!/bin/sh

TEXTFILE="/var/prometheus/backhaul_latency.prom"
TARGET="172.20.3.254"

RESULT=$(ping -c 10 -W 2 "$TARGET" 2>&1)

if echo "$RESULT" | grep -q "packet loss"; then
  LOSS=$(echo "$RESULT" | grep "packet loss" | awk -F',' '{print $3}' | awk '{print $1}' | tr -d '%')
  
  # Format: round-trip min/avg/max = 1.149/1.568/2.147 ms
  if echo "$RESULT" | grep -q "min/avg/max"; then
    STATS=$(echo "$RESULT" | grep "min/avg/max" | awk -F= '{print $2}' | awk '{print $1}')
    MIN=$(echo "$STATS" | cut -d/ -f1)
    AVG=$(echo "$STATS" | cut -d/ -f2)
    MAX=$(echo "$STATS" | cut -d/ -f3)
  else
    MIN=0; AVG=0; MAX=0
  fi
else
  LOSS=100
  MIN=0; AVG=0; MAX=0
fi

# Calculate jitter as (max-min)
JITTER=$(echo "scale=3; $MAX - $MIN" | bc)

cat > "$TEXTFILE.$$" << EOF
# HELP backhaul_latency_min_ms Minimum latency to main router
# TYPE backhaul_latency_min_ms gauge
backhaul_latency_min_ms $MIN

# HELP backhaul_latency_avg_ms Average latency to main router
# TYPE backhaul_latency_avg_ms gauge
backhaul_latency_avg_ms $AVG

# HELP backhaul_latency_max_ms Maximum latency to main router
# TYPE backhaul_latency_max_ms gauge
backhaul_latency_max_ms $MAX

# HELP backhaul_latency_jitter_ms Latency jitter (max-min)
# TYPE backhaul_latency_jitter_ms gauge
backhaul_latency_jitter_ms $JITTER

# HELP backhaul_packet_loss_percent Packet loss to main router
# TYPE backhaul_packet_loss_percent gauge
backhaul_packet_loss_percent $LOSS

# HELP backhaul_latency_last_check_timestamp Last backhaul latency check
# TYPE backhaul_latency_last_check_timestamp gauge
backhaul_latency_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFLATENCY

chmod +x "$SCRIPTS_DIR/backhaul-latency.sh"


cat > "$SCRIPTS_DIR/backhaul-link-quality.sh" << 'EOFQUALITY'
#!/bin/sh

TEXTFILE="/var/prometheus/backhaul_quality.prom"
INTERFACE="phy1-sta0"

STATS=$(iw dev "$INTERFACE" station dump 2>/dev/null)

if [ -z "$STATS" ]; then
  echo "# WiFi station stats not available" > "$TEXTFILE.$$"
  mv "$TEXTFILE.$$" "$TEXTFILE"
  exit 1
fi

# Parse with precise patterns and head -1 to avoid duplicate matches
SIGNAL=$(echo "$STATS" | grep -E "^\s+signal:\s+" | head -1 | awk '{print $2}')
SIGNAL_AVG=$(echo "$STATS" | grep -E "^\s+signal avg:" | head -1 | awk '{print $3}')
RX_BITRATE=$(echo "$STATS" | grep "rx bitrate:" | awk '{print $3}')
TX_BITRATE=$(echo "$STATS" | grep "tx bitrate:" | awk '{print $3}')
RX_PACKETS=$(echo "$STATS" | grep "rx packets:" | awk '{print $3}')
TX_PACKETS=$(echo "$STATS" | grep "tx packets:" | awk '{print $3}')
TX_RETRIES=$(echo "$STATS" | grep "tx retries:" | awk '{print $3}')
TX_FAILED=$(echo "$STATS" | grep "tx failed:" | awk '{print $3}')

# Calculate retry rate
if [ -n "$TX_PACKETS" ] && [ "$TX_PACKETS" -gt 0 ] && [ -n "$TX_RETRIES" ]; then
  RETRY_RATE=$(echo "scale=2; $TX_RETRIES * 100 / $TX_PACKETS" | bc)
else
  RETRY_RATE=0
fi

cat > "$TEXTFILE.$$" << EOF
# HELP backhaul_signal_dbm WiFi signal strength in dBm
# TYPE backhaul_signal_dbm gauge
backhaul_signal_dbm ${SIGNAL:-0}

# HELP backhaul_signal_avg_dbm Average WiFi signal strength in dBm
# TYPE backhaul_signal_avg_dbm gauge
backhaul_signal_avg_dbm ${SIGNAL_AVG:-0}

# HELP backhaul_rx_bitrate_mbps RX bitrate in Mbps
# TYPE backhaul_rx_bitrate_mbps gauge
backhaul_rx_bitrate_mbps ${RX_BITRATE:-0}

# HELP backhaul_tx_bitrate_mbps TX bitrate in Mbps
# TYPE backhaul_tx_bitrate_mbps gauge
backhaul_tx_bitrate_mbps ${TX_BITRATE:-0}

# HELP backhaul_rx_packets_total Total RX packets
# TYPE backhaul_rx_packets_total counter
backhaul_rx_packets_total ${RX_PACKETS:-0}

# HELP backhaul_tx_packets_total Total TX packets
# TYPE backhaul_tx_packets_total counter
backhaul_tx_packets_total ${TX_PACKETS:-0}

# HELP backhaul_tx_retries_total Total TX retries
# TYPE backhaul_tx_retries_total counter
backhaul_tx_retries_total ${TX_RETRIES:-0}

# HELP backhaul_tx_failed_total Total TX failures
# TYPE backhaul_tx_failed_total counter
backhaul_tx_failed_total ${TX_FAILED:-0}

# HELP backhaul_tx_retry_rate_percent TX retry rate percentage
# TYPE backhaul_tx_retry_rate_percent gauge
backhaul_tx_retry_rate_percent $RETRY_RATE

# HELP backhaul_quality_last_check_timestamp Last link quality check
# TYPE backhaul_quality_last_check_timestamp gauge
backhaul_quality_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFQUALITY

chmod +x "$SCRIPTS_DIR/backhaul-link-quality.sh"

(crontab -l 2>/dev/null | grep -v backhaul-latency.sh | grep -v backhaul-link-quality.sh; cat << 'EOFCRON'

# Backhaul monitoring
*/1 * * * * /usr/bin/backhaul-latency.sh
*/1 * * * * /usr/bin/backhaul-link-quality.sh
EOFCRON
) | crontab -

/etc/init.d/cron restart


# test
/usr/bin/backhaul-latency.sh
/usr/bin/backhaul-link-quality.sh
cat /var/prometheus/backhaul_*.prom