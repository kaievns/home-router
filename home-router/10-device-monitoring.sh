#!/bin/sh
# Device Status Monitoring Setup

set -e

echo "=== Device Status & New Device Detection Setup ==="
echo ""

############################################################
# device status tracking
############################################################
cat > /usr/bin/device-status.sh << 'EOFSTATUS'
#!/bin/sh
# Device online/offline status monitoring

TEXTFILE="/var/prometheus/device_status.prom"
DHCP_LEASES="/tmp/dhcp.leases"

# Check if DHCP leases exist
if [ ! -f "$DHCP_LEASES" ]; then
  echo "# DHCP leases not found" > "$TEXTFILE.$$"
  mv "$TEXTFILE.$$" "$TEXTFILE"
  exit 0
fi

# Start metrics file
cat > "$TEXTFILE.$$" << EOF
# HELP device_status Device online status (1=online, 0=offline)
# TYPE device_status gauge
EOF

# Read DHCP leases and ping each device
# Format: timestamp mac ip hostname clientid
while read -r timestamp mac ip hostname rest; do
  # Skip empty lines
  [ -z "$ip" ] && continue
  
  # Ping device (1 packet, 1 second timeout)
  if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    status=1
  else
    status=0
  fi
  
  # Clean hostname (replace * with unknown)
  [ "$hostname" = "*" ] && hostname="unknown"
  
  # Write metric
  echo "device_status{ip=\"$ip\",mac=\"$mac\",hostname=\"$hostname\"} $status" >> "$TEXTFILE.$$"
done < "$DHCP_LEASES"

# Add timestamp
cat >> "$TEXTFILE.$$" << EOF

# HELP device_status_last_check_timestamp Last device status check
# TYPE device_status_last_check_timestamp gauge
device_status_last_check_timestamp $(date +%s)
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFSTATUS

chmod +x /usr/bin/device-status.sh

############################################################
# new devices tracker
############################################################
cat > /usr/bin/new-device-detector.sh << 'EOFNEWDEV'
#!/bin/sh
# New device detection

TEXTFILE="/var/prometheus/new_devices.prom"
DHCP_LEASES="/tmp/dhcp.leases"
KNOWN_DEVICES="/etc/known_devices.list"
NEW_DEVICE_AGE=604800  # 7 days in seconds

# Create known devices file if it doesn't exist
touch "$KNOWN_DEVICES"

# Check if DHCP leases exist
if [ ! -f "$DHCP_LEASES" ]; then
  echo "# DHCP leases not found" > "$TEXTFILE.$$"
  mv "$TEXTFILE.$$" "$TEXTFILE"
  exit 0
fi

# Start metrics file
cat > "$TEXTFILE.$$" << EOF
# HELP network_new_device New device detected on network (1=new, expires after 7 days)
# TYPE network_new_device gauge
EOF

NOW=$(date +%s)

# Read current DHCP leases
while read -r timestamp mac ip hostname rest; do
  [ -z "$mac" ] && continue
  
  # Check if MAC is in known devices list
  if ! grep -q "^$mac" "$KNOWN_DEVICES" 2>/dev/null; then
    # New device! Add to known list with timestamp
    echo "$mac $NOW $ip $hostname" >> "$KNOWN_DEVICES"
  fi
done < "$DHCP_LEASES"

# Read known devices and generate metrics for recent ones
while read -r mac first_seen ip hostname; do
  age=$((NOW - first_seen))
  
  # Only show devices seen in last 7 days
  if [ "$age" -lt "$NEW_DEVICE_AGE" ]; then
    [ "$hostname" = "*" ] && hostname="unknown"
    echo "network_new_device{mac=\"$mac\",ip=\"$ip\",hostname=\"$hostname\",first_seen=\"$first_seen\"} 1" >> "$TEXTFILE.$$"
  fi
done < "$KNOWN_DEVICES"

# Clean up old entries from known devices (older than 30 days)
CLEANUP_AGE=2592000  # 30 days
grep -v "^$" "$KNOWN_DEVICES" | while read -r mac first_seen ip hostname; do
  age=$((NOW - first_seen))
  if [ "$age" -lt "$CLEANUP_AGE" ]; then
    echo "$mac $first_seen $ip $hostname"
  fi
done > "$KNOWN_DEVICES.tmp"
mv "$KNOWN_DEVICES.tmp" "$KNOWN_DEVICES"

# Add timestamp
cat >> "$TEXTFILE.$$" << EOF

# HELP network_new_device_check_timestamp Last new device check
# TYPE network_new_device_check_timestamp gauge
network_new_device_check_timestamp $NOW
EOF

mv "$TEXTFILE.$$" "$TEXTFILE"
EOFNEWDEV

chmod +x /usr/bin/new-device-detector.sh


cat >> /etc/crontabs/root << 'EOF'

# Device monitoring
*/5 * * * * /usr/bin/device-status.sh
*/1 * * * * /usr/bin/new-device-detector.sh
EOF

/etc/init.d/cron restart
