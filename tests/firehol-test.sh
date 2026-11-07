#!/bin/sh
# Runs the scripts 05-firehol.sh installs, against stubbed wget, nft, and logger.
# Usage: sh tests/firehol-test.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SETUP="$ROOT/home-router/05-firehol.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
check() {
    if [ "$2" = 0 ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $1"
    fi
}
is_true() { "$@" >/dev/null 2>&1; echo $?; }
is_false() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }

extract() {
    sed -n "\|^cat > /usr/bin/$1 << 'EOF'\$|,/^EOF\$/p" "$SETUP" | sed '1d;$d' > "$WORK/$1"
    chmod +x "$WORK/$1"
}
extract firehol-filter.sh
extract firehol-refresh.sh
check "filter script parses" "$(is_true sh -n "$WORK/firehol-filter.sh")"
check "refresh script parses" "$(is_true sh -n "$WORK/firehol-refresh.sh")"

filtered() { printf '%s\n' "$1" | "$WORK/firehol-filter.sh"; }
kept() { check "keeps $1" "$(is_true test "$(filtered "$1")" = "$1")"; }
dropped() { check "drops $1" "$(is_true test -z "$(filtered "$1")")"; }

# Routable entries, including the neighbours of each reserved range.
for e in 1.2.3.4 45.0.0.0/24 8.8.4.4 11.0.0.0/8 9.255.255.255 \
    172.15.255.255 172.32.0.0 100.63.255.255 100.128.0.0 \
    192.167.255.255 192.169.0.0 223.255.255.255; do
    kept "$e"
done

# Internal subnets, the CGNAT wan gateway, and each reserved range.
for e in 172.20.1.254 172.20.4.29 172.16.1.69 172.16.0.0/12 100.93.128.1 \
    100.64.0.0/10 10.0.0.0/8 10.1.2.3 192.168.0.0/16 192.168.1.1 127.0.0.0/8 \
    127.0.0.1 169.254.0.0/16 169.254.129.1 0.0.0.0/8 198.18.0.0/15 \
    192.0.2.1 198.51.100.1 203.0.113.1 192.0.0.1 224.0.0.0/3 224.0.0.251 \
    240.0.0.1 255.255.255.255; do
    dropped "$e"
done

# Broader entries that contain reserved space.
for e in 0.0.0.0/0 172.0.0.0/8 100.0.0.0/8 192.0.0.0/8 128.0.0.0/1; do
    dropped "$e"
done

# Input that must never reach an nft batch.
for e in '# comment' '' abc ::1 2001:db8::/32 256.1.1.1 1.2.3.999 1.2.3.4/33 \
    '1.2.3.4; flush ruleset' '1.2.3.4 }' 1.2.3; do
    dropped "$e"
done

check "strips trailing comments" \
    "$(is_true test "$(filtered '1.2.3.4 # bad host')" = 1.2.3.4)"
check "strips CRLF" \
    "$(is_true test "$(printf '1.2.3.4\r\n' | "$WORK/firehol-filter.sh")" = 1.2.3.4)"
check "deduplicates" "$(is_true test \
    "$(printf '1.2.3.4\n1.2.3.4\n5.6.7.8\n' | "$WORK/firehol-filter.sh" | wc -l | tr -d ' ')" = 2)"

# Stubs for the refresh runs.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/logger" << 'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUBS/wget" << 'EOF'
#!/bin/sh
case "$4" in *"$WGET_FAIL_ON"*) [ -n "$WGET_FAIL_ON" ] && exit 1;; esac
cat "$FIXTURE" > "$3"
EOF
cat > "$STUBS/nft" << 'EOF'
#!/bin/sh
cp "$2" "$NFT_CAPTURE"
exit "${NFT_EXIT:-0}"
EOF
chmod +x "$STUBS"/*

BIG="$WORK/big.txt"
awk 'BEGIN { print "# header"; print "172.16.0.0/12"; print "100.64.0.0/10"
    for (i = 0; i < 1500; i++) printf "45.%d.%d.0/24\n", int(i / 250), i % 250 }' > "$BIG"
SMALL="$WORK/small.txt"
printf '45.0.0.0/24\n172.16.0.0/12\n' > "$SMALL"

LIST="$WORK/list.txt"
CAPTURE="$WORK/capture.nft"
refresh() {
    rm -f "$CAPTURE"
    env PATH="$STUBS:$PATH" FIXTURE="$1" NFT_EXIT="$2" WGET_FAIL_ON="$3" \
        NFT_CAPTURE="$CAPTURE" LIST_FILE="$LIST" TEMP_DIR="$WORK/tmp" \
        FILTER="$WORK/firehol-filter.sh" "$WORK/firehol-refresh.sh" >/dev/null 2>&1
}

echo old > "$LIST"
refresh "$BIG" 0 ""
check "refresh succeeds" $?
check "first batch line flushes the set" "$(is_true test \
    "$(sed -n 1p "$CAPTURE")" = "flush set inet fw4 firehol_blocklist")"
check "second batch line adds to the set" "$(is_true test \
    "$(sed -n 2p "$CAPTURE")" = "add element inet fw4 firehol_blocklist {")"
check "batch closes the element list" "$(is_true test "$(tail -1 "$CAPTURE")" = "}")"
check "batch carries no reserved space" \
    "$(is_false grep -qE '^(172\.16|100\.64)' "$CAPTURE")"
check "list file is replaced" "$(is_true test "$(wc -l < "$LIST" | tr -d ' ')" = 1500)"
check "list file carries no reserved space" \
    "$(is_false grep -qE '^(172\.16|100\.64)' "$LIST")"
check "temp dir is removed" "$(is_false test -e "$WORK/tmp")"

echo old > "$LIST"
refresh "$BIG" 0 spamhaus_edrop
check "one failed download still loads the rest" $?
check "partial download replaces the list" "$(is_true test "$(wc -l < "$LIST" | tr -d ' ')" = 1500)"

echo old > "$LIST"
refresh "$SMALL" 0 ""
check "too few entries fails" "$(is_false test $? = 0)"
check "too few entries leaves the set alone" "$(is_false test -e "$CAPTURE")"
check "too few entries keeps the list" "$(is_true test "$(cat "$LIST")" = old)"

echo old > "$LIST"
refresh "$BIG" 1 ""
check "nft failure fails" "$(is_false test $? = 0)"
check "nft failure keeps the list" "$(is_true test "$(cat "$LIST")" = old)"
check "nft failure removes the temp dir" "$(is_false test -e "$WORK/tmp")"

# Declarations in 05-firehol.sh.
declared() { check "declares $1" "$(is_true grep -qF "uci set firewall.$1" "$SETUP")"; }
declared "fh_in.src='wan'"
declared "fh_fwd_src.src='wan'"
declared "fh_fwd_dst.dest='wan'"
declared 'firehol_set.loadfile="$LIST_FILE"'
check "drop rules sit ahead of the wan allow rules" \
    "$(is_true test "$(grep -c '^uci reorder firewall.fh_' "$SETUP")" = 3)"
check "load runs after the rules are scoped" "$(is_true test \
    "$(grep -n 'fh_fwd_dst.dest' "$SETUP" | cut -d: -f1)" -lt \
    "$(grep -n '^/usr/bin/firehol-refresh.sh' "$SETUP" | cut -d: -f1)")"

# The legacy ipset path stays gone.
LEGACY='ipset (create|restore|save|swap|destroy|list)|firehol-ipset\.save|firehol-blocklist enable|init\.d/firehol-blocklist|[SK][0-9]+firehol|apk add ipset'
check "no script uses the legacy ipset" "$(is_false grep -rEn "$LEGACY" \
    "$ROOT/common" "$ROOT/home-router" "$ROOT/lab-router" "$ROOT/repeater")"
check "docs don't describe the legacy ipset" \
    "$(is_false grep -En "$LEGACY" "$ROOT/SYSUPGRADE.md")"
check "diagnostics read the nft set" "$(is_true grep -q \
    'nft list set inet fw4 firehol_blocklist' "$ROOT/home-router/99-diagnostics.sh")"
check "backup keeps the list file" "$(is_true grep -qxF \
    'add_keep /etc/firehol-blocklist.txt' "$ROOT/common/09-backup-restore.sh")"

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
