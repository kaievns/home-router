#!/bin/sh

#
# nlbwmon Bandwidth Tracking Setup
#

set -e

opkg update
opkg install nlbwmon luci-app-nlbwmon

cat > /etc/config/nlbwmon << 'EOF'
config nlbwmon
	option database_directory '/var/lib/nlbwmon'
	option database_limit '10000'
	option database_generations '10'
	option commit_interval '24h'
	option refresh_interval '30s'
	option protocol_database '/usr/share/nlbwmon/protocols'
	
	# Monitor all interfaces
	list local_network '172.20.0.0/16'
	list local_network '172.16.0.0/16'
	
	# Don't monitor router's own traffic
	option database_prealloc '1'
EOF

/etc/init.d/nlbwmon enable
/etc/init.d/nlbwmon start

# custom bandwidth exporter script
cat > /usr/bin/bandwidth-usage.sh << 'EOFBW'
#!/bin/sh
TEXTFILE="/var/prometheus/bandwidth.prom"

# Get data
DATA=$(nlbw -c json -g ip,mac 2>/dev/null)
[ -z "$DATA" ] && exit 0

cat > "$TEXTFILE.$$" << EOF
# HELP network_device_rx_bytes_total Total bytes received
# TYPE network_device_rx_bytes_total counter
# HELP network_device_tx_bytes_total Total bytes transmitted
# TYPE network_device_tx_bytes_total counter
EOF

# Parse JSON
echo "$DATA" | jq -r '.data[] | @json' | while read -r row; do
  mac=$(echo "$row" | jq -r '.[0]')
  ip=$(echo "$row" | jq -r '.[1]')
  rx=$(echo "$row" | jq -r '.[3]')
  tx=$(echo "$row" | jq -r '.[5]')
  
  [ -z "$ip" ] && ip="unknown"

  # Using _total suffix for counters
  echo "network_device_rx_bytes_total{ip=\"$ip\",mac=\"$mac\"} $rx" >> "$TEXTFILE.$$"
  echo "network_device_tx_bytes_total{ip=\"$ip\",mac=\"$mac\"} $tx" >> "$TEXTFILE.$$"
done

echo "network_bandwidth_last_update_timestamp $(date +%s)" >> "$TEXTFILE.$$"
mv "$TEXTFILE.$$" "$TEXTFILE"
EOFBW

chmod +x /usr/bin/bandwidth-usage.sh

#  top talkers script
cat > /usr/bin/bandwidth-top-talkers.sh << 'EOFTOP'
#!/bin/sh
# Fixed bandwidth-top-talkers.sh - uses JSON

TEXTFILE="/var/prometheus/bandwidth_top.prom"

# Get data in JSON
DATA=$(nlbw -c json -g ip -o ip,conns,rx_bytes,tx_bytes 2>/dev/null)

if [ -z "$DATA" ]; then
  echo "# nlbwmon data not ready yet" > "$TEXTFILE.$$"
  mv "$TEXTFILE.$$" "$TEXTFILE"
  exit 0
fi

# Parse and calculate totals, get top 10
# data array: [ip, conns, rx_bytes, tx_bytes]
TOP=$(echo "$DATA" | jq -r '.data[] | 
  {ip: .[0], rx: .[2], tx: .[3], total: (.[2] + .[3])} |
  "\(.total) \(.ip) \(.rx) \(.tx)"' | 
  sort -rn | head -10)

# Create metrics
cat > "$TEXTFILE.$$" << EOF
# HELP network_top_talker_total_bytes Total traffic for top bandwidth users
# TYPE network_top_talker_total_bytes gauge
# HELP network_top_talker_rx_bytes Received bytes for top bandwidth users
# TYPE network_top_talker_rx_bytes gauge
# HELP network_top_talker_tx_bytes Transmitted bytes for top bandwidth users
# TYPE network_top_talker_tx_bytes gauge
# HELP network_top_talker_rank Rank of top bandwidth user (1=highest)
# TYPE network_top_talker_rank gauge
EOF

rank=1
echo "$TOP" | while read -r total ip rx tx; do
  echo "network_top_talker_total_bytes{ip=\"$ip\",rank=\"$rank\"} $total" >> "$TEXTFILE.$$"
  echo "network_top_talker_rx_bytes{ip=\"$ip\",rank=\"$rank\"} $rx" >> "$TEXTFILE.$$"
  echo "network_top_talker_tx_bytes{ip=\"$ip\",rank=\"$rank\"} $tx" >> "$TEXTFILE.$$"
  echo "network_top_talker_rank{ip=\"$ip\"} $rank" >> "$TEXTFILE.$$"
  rank=$((rank + 1))
done

# Add timestamp
cat >> "$TEXTFILE.$$" << EOF

# HELP network_top_talkers_last_update_timestamp Last top talkers update
# TYPE network_top_talkers_last_update_timestamp gauge
network_top_talkers_last_update_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFTOP

chmod +x /usr/bin/bandwidth-top-talkers.sh

cat >> /etc/crontabs/root << 'EOF'

# Bandwidth tracking
*/1 * * * * /usr/bin/bandwidth-usage.sh
*/5 * * * * /usr/bin/bandwidth-top-talkers.sh
EOF

/etc/init.d/cron restart
