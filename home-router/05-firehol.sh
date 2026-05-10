#!/bin/sh

#
# Firehol IP blocking via fw4-managed ipset.
#
# Architecture:
#   - The ipset and the drop rules are declared to fw4 via UCI.
#     fw4 generates the corresponding nft set and rules on every
#     /etc/init.d/firewall reload — so our rules survive reloads.
#   - The kernel-level ipset is populated by /usr/bin/firehol-refresh.sh
#     (3am cron) and persisted to /etc/firehol-ipset.save.
#   - On boot the init.d script restores the saved ipset.
#
# NOTE: directly using `nft add rule ... @firehol_blocklist` does NOT
# work unless the set is also declared in fw4's view of the ruleset.
# That's why we go through UCI — `nft add rule` adds would silently
# fail with "No such file or directory".
#

opkg update && opkg install ipset

##############################################################
# fw4 declarations: set + drop rules
##############################################################

# The set declaration. fw4 ignores 'storage'; the kernel-level ipset
# is created separately below.
uci set firewall.firehol_set='ipset'
uci set firewall.firehol_set.name='firehol_blocklist'
uci set firewall.firehol_set.family='ipv4'
uci set firewall.firehol_set.match='src_net'

# proto='all' so we don't only block tcp/udp (UCI default).
uci set firewall.fh_in='rule'
uci set firewall.fh_in.name='Block-Firehol-Input'
uci set firewall.fh_in.src='*'
uci set firewall.fh_in.proto='all'
uci set firewall.fh_in.ipset='firehol_blocklist src'
uci set firewall.fh_in.target='DROP'

uci set firewall.fh_fwd_src='rule'
uci set firewall.fh_fwd_src.name='Block-Firehol-Forward-Src'
uci set firewall.fh_fwd_src.src='*'
uci set firewall.fh_fwd_src.dest='*'
uci set firewall.fh_fwd_src.proto='all'
uci set firewall.fh_fwd_src.ipset='firehol_blocklist src'
uci set firewall.fh_fwd_src.target='DROP'

uci set firewall.fh_fwd_dst='rule'
uci set firewall.fh_fwd_dst.name='Block-Firehol-Forward-Dst'
uci set firewall.fh_fwd_dst.src='*'
uci set firewall.fh_fwd_dst.dest='*'
uci set firewall.fh_fwd_dst.proto='all'
uci set firewall.fh_fwd_dst.ipset='firehol_blocklist dest'
uci set firewall.fh_fwd_dst.target='DROP'

uci commit firewall

# Kernel-level ipset must exist before fw4 references it
ipset create firehol_blocklist hash:net maxelem 131072 -exist

/etc/init.d/firewall reload

##############################################################
# Refresh script: download + bulk-load + persist. No rule
# management — fw4 owns the rules now.
##############################################################

cat > /usr/bin/firehol-refresh.sh << 'EOF'
#!/bin/sh

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

ipset create "$SET_NAME" hash:net maxelem $MAXELEM -exist
ipset destroy "$SET_TEMP" 2>/dev/null
ipset create "$SET_TEMP" hash:net maxelem $MAXELEM

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

# Single batch load — orders of magnitude faster than per-IP `ipset add`
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

# Persist for boot
ipset save "$SET_NAME" > /etc/firehol-ipset.save 2>/dev/null
log_msg "Saved ipset to /etc/firehol-ipset.save"

FINAL_COUNT=$(ipset list "$SET_NAME" | grep -c '^[0-9]')
log_msg "Blocklist updated: Downloaded $TOTAL_DOWNLOADED entries, loaded $FINAL_COUNT unique IPs"

exit 0
EOF

chmod +x /usr/bin/firehol-refresh.sh

# 3am refresh
(crontab -l 2>/dev/null | grep -v firehol; echo "0 3 * * * /usr/bin/firehol-refresh.sh") | crontab -

##############################################################
# Init.d: restore saved set on boot. fw4 owns the rules.
##############################################################

cat > /etc/init.d/firehol-blocklist << 'EOF'
#!/bin/sh /etc/rc.common

START=19
STOP=89

start() {
    if [ -f /etc/firehol-ipset.save ]; then
        ipset restore -! < /etc/firehol-ipset.save
    else
        ipset create firehol_blocklist hash:net maxelem 131072 -exist
    fi
    logger -t firehol "Blocklist loaded on boot"
}

stop() {
    ipset save firehol_blocklist > /etc/firehol-ipset.save 2>/dev/null
    logger -t firehol "Blocklist saved"
}
EOF

chmod +x /etc/init.d/firehol-blocklist
/etc/init.d/firehol-blocklist enable
