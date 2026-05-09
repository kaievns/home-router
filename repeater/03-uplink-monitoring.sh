#!/bin/sh

# Uplink monitoring — latency to the home router and raw
# interface stats on the uplink trunk (eth1, eth1.20).

TEXTFILE_DIR="/var/prometheus"
SCRIPTS_DIR="/usr/bin"
MAIN_ROUTER="172.20.1.254"

mkdir -p "$TEXTFILE_DIR"

############################################################################
# Latency to home router
############################################################################
cat > "$SCRIPTS_DIR/uplink-latency.sh" << 'EOFLATENCY'
#!/bin/sh
TEXTFILE="/var/prometheus/uplink_latency.prom"
TARGET="172.20.1.254"

RESULT=$(ping -c 5 -W 2 "$TARGET" 2>&1)

if echo "$RESULT" | grep -q "packet loss"; then
  LOSS=$(echo "$RESULT" | grep "packet loss" | awk -F',' '{print $3}' | awk '{print $1}' | tr -d '%')

  if echo "$RESULT" | grep -q "min/avg/max"; then
    STATS=$(echo "$RESULT" | grep "min/avg/max" | awk -F= '{print $2}' | awk '{print $1}')
    MIN=$(echo "$STATS" | cut -d/ -f1)
    AVG=$(echo "$STATS" | cut -d/ -f2)
    MAX=$(echo "$STATS" | cut -d/ -f3)
  else
    MIN=0; AVG=0; MAX=0
  fi
else
  LOSS=100; MIN=0; AVG=0; MAX=0
fi

JITTER=$(echo "scale=3; $MAX - $MIN" | bc)

cat > "$TEXTFILE.$$" << EOF
# HELP uplink_latency_min_ms Minimum latency to home router
# TYPE uplink_latency_min_ms gauge
uplink_latency_min_ms $MIN

# HELP uplink_latency_avg_ms Average latency to home router
# TYPE uplink_latency_avg_ms gauge
uplink_latency_avg_ms $AVG

# HELP uplink_latency_max_ms Maximum latency to home router
# TYPE uplink_latency_max_ms gauge
uplink_latency_max_ms $MAX

# HELP uplink_latency_jitter_ms Latency jitter (max-min)
# TYPE uplink_latency_jitter_ms gauge
uplink_latency_jitter_ms $JITTER

# HELP uplink_packet_loss_percent Packet loss to home router
# TYPE uplink_packet_loss_percent gauge
uplink_packet_loss_percent $LOSS

# HELP uplink_latency_last_check_timestamp Last uplink latency check
# TYPE uplink_latency_last_check_timestamp gauge
uplink_latency_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFLATENCY

chmod +x "$SCRIPTS_DIR/uplink-latency.sh"


############################################################################
# Interface stats for uplink ports
############################################################################
cat > "$SCRIPTS_DIR/uplink-link-health.sh" << 'EOFHEALTH'
#!/bin/sh

TEXTFILE="/var/prometheus/uplink_health.prom"

get_iface_stats() {
  local iface="$1"
  local label="$2"

  if [ -d "/sys/class/net/$iface" ]; then
    local rx_bytes=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    local tx_bytes=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    local rx_packets=$(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null || echo 0)
    local tx_packets=$(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null || echo 0)
    local rx_errors=$(cat /sys/class/net/$iface/statistics/rx_errors 2>/dev/null || echo 0)
    local tx_errors=$(cat /sys/class/net/$iface/statistics/tx_errors 2>/dev/null || echo 0)
    local rx_dropped=$(cat /sys/class/net/$iface/statistics/rx_dropped 2>/dev/null || echo 0)
    local tx_dropped=$(cat /sys/class/net/$iface/statistics/tx_dropped 2>/dev/null || echo 0)
    local operstate=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
    local link_up=0
    [ "$operstate" = "up" ] && link_up=1

    cat << EOF
uplink_link_up{vlan="$label",interface="$iface"} $link_up
uplink_rx_bytes_total{vlan="$label",interface="$iface"} $rx_bytes
uplink_tx_bytes_total{vlan="$label",interface="$iface"} $tx_bytes
uplink_rx_packets_total{vlan="$label",interface="$iface"} $rx_packets
uplink_tx_packets_total{vlan="$label",interface="$iface"} $tx_packets
uplink_rx_errors_total{vlan="$label",interface="$iface"} $rx_errors
uplink_tx_errors_total{vlan="$label",interface="$iface"} $tx_errors
uplink_rx_dropped_total{vlan="$label",interface="$iface"} $rx_dropped
uplink_tx_dropped_total{vlan="$label",interface="$iface"} $tx_dropped
EOF
  fi
}

{
cat << 'HEADER'
# HELP uplink_link_up Whether the uplink interface is up (1=up, 0=down)
# TYPE uplink_link_up gauge
# HELP uplink_rx_bytes_total Total bytes received on uplink
# TYPE uplink_rx_bytes_total counter
# HELP uplink_tx_bytes_total Total bytes transmitted on uplink
# TYPE uplink_tx_bytes_total counter
# HELP uplink_rx_packets_total Total packets received on uplink
# TYPE uplink_rx_packets_total counter
# HELP uplink_tx_packets_total Total packets transmitted on uplink
# TYPE uplink_tx_packets_total counter
# HELP uplink_rx_errors_total Total RX errors on uplink
# TYPE uplink_rx_errors_total counter
# HELP uplink_tx_errors_total Total TX errors on uplink
# TYPE uplink_tx_errors_total counter
# HELP uplink_rx_dropped_total Total RX dropped on uplink
# TYPE uplink_rx_dropped_total counter
# HELP uplink_tx_dropped_total Total TX dropped on uplink
# TYPE uplink_tx_dropped_total counter
HEADER

get_iface_stats "eth1"    "physical"
get_iface_stats "eth1.20" "iot"

cat << EOF

# HELP uplink_health_last_check_timestamp Last uplink health check
# TYPE uplink_health_last_check_timestamp gauge
uplink_health_last_check_timestamp $(date +%s)
EOF
} > "$TEXTFILE.$$"

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFHEALTH

chmod +x "$SCRIPTS_DIR/uplink-link-health.sh"


(crontab -l 2>/dev/null | \
  grep -v uplink-latency.sh | \
  grep -v uplink-link-health.sh; cat << 'EOFCRON'

# Uplink monitoring
*/1 * * * * /usr/bin/uplink-latency.sh
*/1 * * * * /usr/bin/uplink-link-health.sh
EOFCRON
) | crontab -

/etc/init.d/cron restart


# Test
/usr/bin/uplink-latency.sh
/usr/bin/uplink-link-health.sh
echo
echo "=== Uplink latency ==="
cat /var/prometheus/uplink_latency.prom
echo
echo "=== Uplink health ==="
cat /var/prometheus/uplink_health.prom
