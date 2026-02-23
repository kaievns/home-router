#!/bin/sh

#
# Exporting adguard stats into prometheus via the textfile exporter
#

# Create /etc/adguard-creds.conf, we'll need that to access the stats
cat > /etc/adguard-creds.conf << EOF
ADGUARD_USER="admin"
ADGUARD_PASS="yourpassword"
EOF

chmod 600 /etc/adguard-creds.conf

############################################
# the exporter script
############################################
cat > "/usr/bin/adguard-exporter.sh" << 'EOFADGUARD'
#!/bin/sh
# AdGuard Home metrics exporter with credentials

TEXTFILE="/var/prometheus/adguard.prom"
ADGUARD_URL="http://172.20.1.254:3030"
CREDS_FILE="/etc/adguard-creds.conf"

# Source credentials
if [ ! -f "$CREDS_FILE" ]; then
  echo "# AdGuard credentials not found" > "$TEXTFILE.$$"
  mv "$TEXTFILE.$$" "$TEXTFILE"
  exit 1
fi

. "$CREDS_FILE"

# Fetch stats from AdGuard
STATS=$(curl -s -u "$ADGUARD_USER:$ADGUARD_PASS" "$ADGUARD_URL/control/stats" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$STATS" ]; then
  echo "# AdGuard stats unavailable" > "$TEXTFILE.$$"
  mv "$TEXTFILE.$$" "$TEXTFILE"
  exit 1
fi

# Parse JSON and create metrics
QUERIES=$(echo "$STATS" | jq -r '.num_dns_queries // 0')
BLOCKED=$(echo "$STATS" | jq -r '.num_blocked_filtering // 0')
SAFEBROWSING=$(echo "$STATS" | jq -r '.num_replaced_safebrowsing // 0')
PARENTAL=$(echo "$STATS" | jq -r '.num_replaced_parental // 0')
AVG_TIME=$(echo "$STATS" | jq -r '.avg_processing_time // 0')

# Calculate block percentage
if [ "$QUERIES" -gt 0 ]; then
  BLOCK_PCT=$(echo "scale=2; $BLOCKED * 100 / $QUERIES" | bc)
else
  BLOCK_PCT="0"
fi

# Get top blocked domain count (if exists)
TOP_BLOCKED=$(echo "$STATS" | jq -r '.top_blocked_domains[0] | to_entries[0].value // 0')

# Write Prometheus metrics
cat > "$TEXTFILE.$$" << EOF
# HELP adguard_dns_queries_total Total DNS queries processed
# TYPE adguard_dns_queries_total counter
adguard_dns_queries_total $QUERIES

# HELP adguard_blocked_queries_total Queries blocked by filtering
# TYPE adguard_blocked_queries_total counter
adguard_blocked_queries_total $BLOCKED

# HELP adguard_safebrowsing_blocked_total Queries blocked by safe browsing
# TYPE adguard_safebrowsing_blocked_total counter
adguard_safebrowsing_blocked_total $SAFEBROWSING

# HELP adguard_parental_blocked_total Queries blocked by parental control
# TYPE adguard_parental_blocked_total counter
adguard_parental_blocked_total $PARENTAL

# HELP adguard_block_percentage Percentage of queries blocked
# TYPE adguard_block_percentage gauge
adguard_block_percentage $BLOCK_PCT

# HELP adguard_avg_processing_time_seconds Average query processing time
# TYPE adguard_avg_processing_time_seconds gauge
adguard_avg_processing_time_seconds $AVG_TIME

# HELP adguard_last_scrape_timestamp Last successful scrape
# TYPE adguard_last_scrape_timestamp gauge
adguard_last_scrape_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFADGUARD

chmod +x "/usr/bin/adguard-exporter.sh"

cat >> /etc/crontabs/root << 'EOF'

# AdGuard stats exporter
*/1 * * * * /usr/bin/adguard-exporter.sh
EOF

/etc/init.d/cron restart