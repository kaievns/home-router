#!/bin/sh

#
# Firehol IP blocking firewall integration using ipset over nft for zero downtime
#

opkg update && opkg install ipset

cat > /usr/bin/firehol-refresh.sh << 'EOF'
#!/bin/sh

# List of blocklists to use (space-separated)
BLOCKLISTS="
firehol_level1
firehol_abusers_1d
spamhaus_drop
spamhaus_edrop
"

SET_NAME="firehol_blocklist"
SET_TEMP="firehol_temp"
LOG_TAG="firehol_ipset"
TEMP_DIR="/tmp/firehol"

log_msg() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date): $1"
}

log_msg "Starting blocklist update..."

# Create temp directory
mkdir -p "$TEMP_DIR"

# Ensure ipset is installed
if ! command -v ipset >/dev/null 2>&1; then
    log_msg "ERROR: ipset not installed"
    exit 1
fi

# Create main ipset if it doesn't exist
ipset create "$SET_NAME" hash:net maxelem 131072 2>/dev/null  # Increased size

# Create temp ipset (clean up old one first)
ipset destroy "$SET_TEMP" 2>/dev/null
ipset create "$SET_TEMP" hash:net maxelem 131072

# Download and merge all lists
TOTAL_DOWNLOADED=0

for LIST in $BLOCKLISTS; do
    URL="https://iplists.firehol.org/files/${LIST}.netset"
    TEMP_FILE="$TEMP_DIR/${LIST}.txt"
    
    log_msg "Downloading $LIST..."
    
    if wget -q -O "$TEMP_FILE" "$URL"; then
        COUNT=$(grep -v '^#' "$TEMP_FILE" | grep -v '^$' | wc -l)
        log_msg "  $LIST: $COUNT entries"
        
        # Add to temp ipset
        grep -v '^#' "$TEMP_FILE" | grep -v '^$' | while read -r IP; do
            ipset add "$SET_TEMP" "$IP" 2>/dev/null
        done
        
        TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + COUNT))
        rm -f "$TEMP_FILE"
    else
        log_msg "  WARNING: Failed to download $LIST"
    fi
done

# Check if we got enough entries
TEMP_COUNT=$(ipset list "$SET_TEMP" | grep -c '^[0-9]')

if [ "$TEMP_COUNT" -lt 1000 ]; then
    log_msg "ERROR: Too few entries ($TEMP_COUNT). Keeping old list."
    ipset destroy "$SET_TEMP"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Atomic swap
log_msg "Performing atomic swap ($TEMP_COUNT unique IPs)..."
ipset swap "$SET_NAME" "$SET_TEMP"
ipset destroy "$SET_TEMP"

# Cleanup temp directory
rm -rf "$TEMP_DIR"

# Ensure firewall rule exists
if ! nft list chain inet fw4 input 2>/dev/null | grep -q "firehol_blocklist"; then
    log_msg "Adding nftables drop rule..."
    nft add rule inet fw4 input ip saddr @firehol_blocklist counter drop
fi

# Save ipset for persistence
ipset save firehol_blocklist > /etc/firehol-ipset.save 2>/dev/null
log_msg "Saving ipset in case of a reboot /etc/firehol-ipset.save"

FINAL_COUNT=$(ipset list "$SET_NAME" | grep -c '^[0-9]')
log_msg "Blocklist updated: Downloaded $TOTAL_DOWNLOADED entries, loaded $FINAL_COUNT unique IPs"

exit 0
EOF

chmod +x /usr/bin/firehol-refresh.sh

# adding 3am refresh
(crontab -l 2>/dev/null | grep -v firehol; echo "0 3 * * * /usr/bin/firehol-refresh.sh") | crontab -

cat > /etc/init.d/firehol-blocklist << 'EOF'
#!/bin/sh /etc/rc.common

START=19
STOP=89

start() {
    # Restore ipset from save file if it exists
    if [ -f /etc/firehol-ipset.save ]; then
        ipset restore < /etc/firehol-ipset.save
    else
        # Create empty set on first boot
        ipset create firehol_blocklist hash:net maxelem 65536 2>/dev/null
    fi
    
    # Ensure firewall rule exists
    nft list chain inet fw4 input 2>/dev/null | grep -q "firehol_blocklist" || \
        nft add rule inet fw4 input ip saddr @firehol_blocklist counter drop
    
    logger -t firehol "Blocklist loaded on boot"
}

stop() {
    # Save ipset before shutdown
    ipset save firehol_blocklist > /etc/firehol-ipset.save 2>/dev/null
    logger -t firehol "Blocklist saved"
}
EOF

chmod +x /etc/init.d/firehol-blocklist
/etc/init.d/firehol-blocklist enable
