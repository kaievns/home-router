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
MAXELEM=131072

log_msg() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date): $1"
}

log_msg "Starting blocklist update..."

mkdir -p "$TEMP_DIR"

if ! command -v ipset >/dev/null 2>&1; then
    log_msg "ERROR: ipset not installed"
    exit 1
fi

# Ensure main set exists with consistent maxelem
ipset create "$SET_NAME" hash:net maxelem $MAXELEM -exist

# Recreate temp set
ipset destroy "$SET_TEMP" 2>/dev/null
ipset create "$SET_TEMP" hash:net maxelem $MAXELEM

# Download all lists into temp dir
TOTAL_DOWNLOADED=0
for LIST in $BLOCKLISTS; do
    URL="https://iplists.firehol.org/files/${LIST}.netset"
    TEMP_FILE="$TEMP_DIR/${LIST}.txt"

    log_msg "Downloading $LIST..."
    if wget -q -O "$TEMP_FILE" "$URL"; then
        COUNT=$(grep -hv '^#' "$TEMP_FILE" | awk 'NF' | wc -l)
        log_msg "  $LIST: $COUNT entries"
        TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + COUNT))
    else
        log_msg "  WARNING: Failed to download $LIST"
    fi
done

# Single batch load via ipset restore — orders of magnitude faster than
# fork+exec'ing `ipset add` for every IP (was multi-minute on the R5C
# for 100k+ entries).
grep -hv '^#' "$TEMP_DIR"/*.txt 2>/dev/null | awk 'NF' | \
    sed "s|^|add $SET_TEMP |" | ipset restore -!

TEMP_COUNT=$(ipset list "$SET_TEMP" 2>/dev/null | grep -c '^[0-9]')

if [ "$TEMP_COUNT" -lt 1000 ]; then
    log_msg "ERROR: Too few entries ($TEMP_COUNT). Keeping old list."
    ipset destroy "$SET_TEMP"
    rm -rf "$TEMP_DIR"
    exit 1
fi

log_msg "Performing atomic swap ($TEMP_COUNT unique IPs)..."
ipset swap "$SET_NAME" "$SET_TEMP"
ipset destroy "$SET_TEMP"

rm -rf "$TEMP_DIR"

# Ensure all firewall rules exist:
#   input  saddr  — block attacks aimed at the router itself
#   forward saddr — block inbound traffic from blocklisted IPs to LAN clients
#   forward daddr — block LAN clients reaching out to blocklisted IPs
ensure_rule() {
    chain="$1"
    match="$2"
    if ! nft list chain inet fw4 "$chain" 2>/dev/null | grep -q "$match @firehol_blocklist"; then
        log_msg "Adding nftables rule: $chain $match"
        nft add rule inet fw4 "$chain" $match @firehol_blocklist counter drop
    fi
}
ensure_rule input   "ip saddr"
ensure_rule forward "ip saddr"
ensure_rule forward "ip daddr"

# Persist for boot
ipset save "$SET_NAME" > /etc/firehol-ipset.save 2>/dev/null
log_msg "Saved ipset to /etc/firehol-ipset.save"

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
        ipset restore -! < /etc/firehol-ipset.save
    else
        # Create empty set on first boot (maxelem matches refresh script)
        ipset create firehol_blocklist hash:net maxelem 131072 -exist
    fi

    ensure_rule() {
        chain="$1"
        match="$2"
        nft list chain inet fw4 "$chain" 2>/dev/null | grep -q "$match @firehol_blocklist" || \
            nft add rule inet fw4 "$chain" $match @firehol_blocklist counter drop
    }
    ensure_rule input   "ip saddr"
    ensure_rule forward "ip saddr"
    ensure_rule forward "ip daddr"

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
