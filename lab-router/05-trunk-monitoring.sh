#!/bin/sh

# Trunk Link Monitoring — Homelab Router
# Monitors latency, packet loss, and VLAN interface health.

TEXTFILE_DIR="/var/prometheus"
SCRIPTS_DIR="/usr/bin"
MAIN_ROUTER="172.20.3.254"

mkdir -p "$TEXTFILE_DIR"

############################################################################
# 1. Trunk latency monitoring
############################################################################

cat > "$SCRIPTS_DIR/trunk-latency.sh" << 'EOFLATENCY'
#!/bin/sh

TEXTFILE="/var/prometheus/trunk_latency.prom"
TARGET="172.20.3.254"

RESULT=$(ping -c 10 -W 2 "$TARGET" 2>&1)

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
  LOSS=100
  MIN=0; AVG=0; MAX=0
fi

JITTER=$(echo "scale=3; $MAX - $MIN" | bc)

cat > "$TEXTFILE.$$" << EOF
# HELP trunk_latency_min_ms Minimum latency to main router
# TYPE trunk_latency_min_ms gauge
trunk_latency_min_ms $MIN

# HELP trunk_latency_avg_ms Average latency to main router
# TYPE trunk_latency_avg_ms gauge
trunk_latency_avg_ms $AVG

# HELP trunk_latency_max_ms Maximum latency to main router
# TYPE trunk_latency_max_ms gauge
trunk_latency_max_ms $MAX

# HELP trunk_latency_jitter_ms Latency jitter (max-min)
# TYPE trunk_latency_jitter_ms gauge
trunk_latency_jitter_ms $JITTER

# HELP trunk_packet_loss_percent Packet loss to main router
# TYPE trunk_packet_loss_percent gauge
trunk_packet_loss_percent $LOSS

# HELP trunk_latency_last_check_timestamp Last trunk latency check
# TYPE trunk_latency_last_check_timestamp gauge
trunk_latency_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFLATENCY

chmod +x "$SCRIPTS_DIR/trunk-latency.sh"


############################################################################
# 2. VLAN interface health monitoring
############################################################################

cat > "$SCRIPTS_DIR/trunk-link-health.sh" << 'EOFHEALTH'
#!/bin/sh

TEXTFILE="/var/prometheus/trunk_health.prom"

# Check each VLAN interface on the trunk
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
trunk_link_up{vlan="$label",interface="$iface"} $link_up
trunk_rx_bytes_total{vlan="$label",interface="$iface"} $rx_bytes
trunk_tx_bytes_total{vlan="$label",interface="$iface"} $tx_bytes
trunk_rx_packets_total{vlan="$label",interface="$iface"} $rx_packets
trunk_tx_packets_total{vlan="$label",interface="$iface"} $tx_packets
trunk_rx_errors_total{vlan="$label",interface="$iface"} $rx_errors
trunk_tx_errors_total{vlan="$label",interface="$iface"} $tx_errors
trunk_rx_dropped_total{vlan="$label",interface="$iface"} $rx_dropped
trunk_tx_dropped_total{vlan="$label",interface="$iface"} $tx_dropped
EOF
  fi
}

{
cat << 'HEADER'
# HELP trunk_link_up Whether the trunk VLAN interface is up (1=up, 0=down)
# TYPE trunk_link_up gauge
# HELP trunk_rx_bytes_total Total bytes received on trunk VLAN
# TYPE trunk_rx_bytes_total counter
# HELP trunk_tx_bytes_total Total bytes transmitted on trunk VLAN
# TYPE trunk_tx_bytes_total counter
# HELP trunk_rx_packets_total Total packets received on trunk VLAN
# TYPE trunk_rx_packets_total counter
# HELP trunk_tx_packets_total Total packets transmitted on trunk VLAN
# TYPE trunk_tx_packets_total counter
# HELP trunk_rx_errors_total Total RX errors on trunk VLAN
# TYPE trunk_rx_errors_total counter
# HELP trunk_tx_errors_total Total TX errors on trunk VLAN
# TYPE trunk_tx_errors_total counter
# HELP trunk_rx_dropped_total Total RX dropped on trunk VLAN
# TYPE trunk_rx_dropped_total counter
# HELP trunk_tx_dropped_total Total TX dropped on trunk VLAN
# TYPE trunk_tx_dropped_total counter
HEADER

get_iface_stats "eth1" "physical"
get_iface_stats "eth1.20" "iot"
get_iface_stats "eth1.30" "homelab"

cat << EOF

# HELP trunk_health_last_check_timestamp Last trunk health check
# TYPE trunk_health_last_check_timestamp gauge
trunk_health_last_check_timestamp $(date +%s)
EOF
} > "$TEXTFILE.$$"

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFHEALTH

chmod +x "$SCRIPTS_DIR/trunk-link-health.sh"



(crontab -l 2>/dev/null | \
  grep -v trunk-latency.sh | \
  grep -v trunk-link-health.sh; cat << 'EOFCRON'

# Trunk monitoring
*/1 * * * * /usr/bin/trunk-latency.sh
*/1 * * * * /usr/bin/trunk-link-health.sh
EOFCRON
) | crontab -

/etc/init.d/cron restart


# Test
/usr/bin/trunk-latency.sh
/usr/bin/trunk-link-health.sh
echo ""
echo "=== Trunk latency ==="
cat /var/prometheus/trunk_latency.prom
echo ""
echo "=== Trunk health ==="
cat /var/prometheus/trunk_health.prom