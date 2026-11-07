#!/bin/sh

#
# Firehol IP blocking. Requirements: specs/firehol-blocklist.md
#
# fw4 owns the nft set and the drop rules, and reloads the set from LIST_FILE
# on every firewall start. firehol-refresh.sh replaces the set's contents and
# LIST_FILE daily.
#

LIST_FILE="/etc/firehol-blocklist.txt"

##############################################################
# Filter: raw list entries in, loadable entries out
##############################################################

cat > /usr/bin/firehol-filter.sh << 'EOF'
#!/bin/sh
# Keeps valid IPv4 entries, deduplicated, minus anything overlapping
# non-routable space.
awk '
function ip2n(s,   o) {
    split(s, o, ".")
    return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
}
BEGIN {
    n = split("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3", r, " ")
    for (i = 1; i <= n; i++) {
        split(r[i], c, "/")
        lo[i] = ip2n(c[1])
        hi[i] = lo[i] + 2 ^ (32 - c[2]) - 1
    }
}
{ sub(/[ \t\r]*(#.*)?$/, "") }
!/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { next }
{
    split($0, p, "/")
    bits = index($0, "/") ? p[2] + 0 : 32
    if (bits > 32) next
    split(p[1], o, ".")
    for (i = 1; i <= 4; i++) if (o[i] + 0 > 255) next
    size = 2 ^ (32 - bits)
    first = int(ip2n(p[1]) / size) * size
    last = first + size - 1
    for (i = 1; i <= n; i++) if (first <= hi[i] && last >= lo[i]) next
    if (!seen[$0]++) print
}'
EOF

chmod +x /usr/bin/firehol-filter.sh

##############################################################
# Refresh: download, filter, load, persist
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
LOG_TAG="firehol_refresh"
MIN_ENTRIES=1000
LIST_FILE="${LIST_FILE:-/etc/firehol-blocklist.txt}"
FILTER="${FILTER:-/usr/bin/firehol-filter.sh}"
TEMP_DIR="${TEMP_DIR:-/tmp/firehol}"

log_msg() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date): $1"
}

give_up() {
    log_msg "ERROR: $1. Keeping old list."
    rm -rf "$TEMP_DIR"
    exit 1
}

log_msg "Starting blocklist update..."
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

for LIST in $BLOCKLISTS; do
    URL="https://iplists.firehol.org/files/${LIST}.netset"
    TEMP_FILE="$TEMP_DIR/${LIST}.txt"
    log_msg "Downloading $LIST..."
    if wget -q -O "$TEMP_FILE" "$URL"; then
        log_msg "  $LIST: $(grep -cv '^#' "$TEMP_FILE") entries"
    else
        log_msg "  WARNING: Failed to download $LIST"
        rm -f "$TEMP_FILE"
    fi
done

cat "$TEMP_DIR"/*.txt 2>/dev/null | "$FILTER" > "$TEMP_DIR/filtered"
COUNT=$(wc -l < "$TEMP_DIR/filtered" | tr -d ' ')
[ "$COUNT" -ge "$MIN_ENTRIES" ] || give_up "Too few entries ($COUNT)"

# One nft transaction: a rejected batch leaves the live set untouched.
{
    echo "flush set inet fw4 $SET_NAME"
    echo "add element inet fw4 $SET_NAME {"
    sed 's/$/,/' "$TEMP_DIR/filtered"
    echo "}"
} > "$TEMP_DIR/load.nft"
nft -f "$TEMP_DIR/load.nft" || give_up "nft rejected the load"

cp "$TEMP_DIR/filtered" "$LIST_FILE.tmp" && mv "$LIST_FILE.tmp" "$LIST_FILE"
rm -rf "$TEMP_DIR"
log_msg "Blocklist updated: $COUNT entries"

exit 0
EOF

chmod +x /usr/bin/firehol-refresh.sh

# 3am refresh
(crontab -l 2>/dev/null | grep -v firehol; echo "0 3 * * * /usr/bin/firehol-refresh.sh") | crontab -

##############################################################
# fw4 declarations: set + drop rules
##############################################################

touch "$LIST_FILE"

uci set firewall.firehol_set='ipset'
uci set firewall.firehol_set.name='firehol_blocklist'
uci set firewall.firehol_set.family='ipv4'
uci set firewall.firehol_set.match='src_net'
uci set firewall.firehol_set.loadfile="$LIST_FILE"

# proto='all' so we don't only block tcp/udp (UCI default).
uci set firewall.fh_in='rule'
uci set firewall.fh_in.name='Block-Firehol-Input'
uci set firewall.fh_in.src='wan'
uci set firewall.fh_in.proto='all'
uci set firewall.fh_in.ipset='firehol_blocklist src'
uci set firewall.fh_in.target='DROP'

uci set firewall.fh_fwd_src='rule'
uci set firewall.fh_fwd_src.name='Block-Firehol-Forward-Src'
uci set firewall.fh_fwd_src.src='wan'
uci set firewall.fh_fwd_src.dest='*'
uci set firewall.fh_fwd_src.proto='all'
uci set firewall.fh_fwd_src.ipset='firehol_blocklist src'
uci set firewall.fh_fwd_src.target='DROP'

uci set firewall.fh_fwd_dst='rule'
uci set firewall.fh_fwd_dst.name='Block-Firehol-Forward-Dst'
uci set firewall.fh_fwd_dst.src='*'
uci set firewall.fh_fwd_dst.dest='wan'
uci set firewall.fh_fwd_dst.proto='all'
uci set firewall.fh_fwd_dst.ipset='firehol_blocklist dest'
uci set firewall.fh_fwd_dst.target='DROP'

# Ahead of the wan allow rules, which would otherwise accept first.
uci reorder firewall.fh_in=0
uci reorder firewall.fh_fwd_src=1
uci reorder firewall.fh_fwd_dst=2

uci commit firewall
/etc/init.d/firewall reload

/usr/bin/firehol-refresh.sh
