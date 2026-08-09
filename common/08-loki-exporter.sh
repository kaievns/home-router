#!/bin/sh
#
# Ships the router syslog to the homelab Loki.
#
# Instead of a ~130MB Grafana Alloy / promtail Go binary behind a musl->glibc
# loader shim (plus a common/10 re-fetch hook to survive sysupgrade), we ship
# logs with a ~4KB shell script: `logread -f` batched and POSTed to Loki with
# curl. Fits the bash+curl+lua-textfile shape of the rest of this repo, nothing
# to re-fetch, nothing kept out of the sysupgrade backup.
#
# Prereq: LOKI_AUTH_USERNAME / LOKI_AUTH_PASSWORD in /etc/local-secrets (off-git,
# chmod 600). The init script sources that file and injects them into the
# shipper's procd env; they are never written into git-tracked files.

# --- deps (25.12 = apk) -----------------------------------------------------
apk update
apk add curl jq

# --- the shipper ------------------------------------------------------------
cat > /usr/bin/loki-shipper.sh << 'LOKI_SHIPPER_SH'
#!/bin/sh
#
# /usr/bin/loki-shipper.sh
#
# Lightweight syslog -> homelab Loki shipper for OpenWrt 25.12 (busybox ash,
# musl). `logread -f | batch | jq | curl`.
#
# Creds come from the environment (LOKI_AUTH_USERNAME / LOKI_AUTH_PASSWORD),
# injected by the procd init script from /etc/local-secrets. Never inlined,
# never on git, and (via the curl config file below) never in `ps`.
#
# Best-effort by design: /var/log is ramfs and resets on reboot, so on a Loki
# outage we retry a couple of times, then DROP the batch and carry on. We never
# block the pipe forever.

set -u

# Loki sits behind the homelab ingress on :80 with basic auth — NOT on :3100.
# Overridable from /etc/local-secrets (LOKI_URL=...) if the endpoint ever moves.
LOKI_URL="${LOKI_URL:-http://loki.homelab/loki/api/v1/push}"

BATCH_MAX=50        # flush after this many lines...
FLUSH_SECS=5        # ...or this many seconds after the batch's first line,
                    #    or after this many seconds of silence, whichever first.
CURL_TIMEOUT=5      # per-attempt curl --max-time (seconds)
CONNECT_TIMEOUT=3   # per-attempt curl --connect-timeout: fail fast on a dead host
MAX_RETRIES=3       # total POST attempts before dropping the batch
RETRY_SLEEP=2       # seconds between attempts

RUNDIR="/tmp/loki-shipper"       # /tmp is ramfs; recreated on every start
FIFO="$RUNDIR/logread.fifo"
BATCH="$RUNDIR/batch.tsv"
PAYLOAD="$RUNDIR/payload.json"
CURLCFG="$RUNDIR/curl.cfg"

# --- label: job = box hostname ---------------------------------------------
JOB=$(uci -q get system.@system[0].hostname 2>/dev/null)
[ -n "$JOB" ] || JOB=$(cat /proc/sys/kernel/hostname 2>/dev/null)
[ -n "$JOB" ] || JOB="openwrt"

# --- creds (from env; default empty so `set -u` is happy) -------------------
: "${LOKI_AUTH_USERNAME:=}"
: "${LOKI_AUTH_PASSWORD:=}"
[ -n "$LOKI_AUTH_USERNAME" ] || \
    logger -t loki-shipper "warning: LOKI_AUTH_USERNAME empty; pushing without basic auth"

# --- nanosecond-timestamp capability probe ----------------------------------
# Stock OpenWrt busybox is built WITHOUT FEATURE_DATE_NANO, so `date +%N`
# prints a literal "N" (not real nanoseconds). Detect once; if unavailable,
# fall back to whole seconds + a per-second counter as the sub-second field so
# stamps stay UNIQUE and STRICTLY INCREASING (plain "seconds + 9 zeros" would
# collide within a second -> Loki dedups identical ts+line and loses ordering).
case "$(date +%N 2>/dev/null)" in
    ''|*[!0-9]*) NANO=0 ;;
    *)           NANO=1 ;;
esac

LAST_SEC=""
SUBCNT=0
TS=""
stamp() {                       # sets global TS; must NOT run in a subshell
    if [ "$NANO" = 1 ]; then
        TS=$(date +%s%N)
    else
        _s=$(date +%s)
        if [ "$_s" = "$LAST_SEC" ]; then
            SUBCNT=$((SUBCNT + 1))
        else
            LAST_SEC="$_s"
            SUBCNT=0
        fi
        TS="${_s}$(printf '%09d' "$SUBCNT")"
    fi
}

count=0
batch_start=""

add_line() {                    # $1 = one raw log line
    stamp
    # record layout: <ns-timestamp><TAB><raw line>. jq splits on the FIRST tab,
    # so tabs inside the log line are preserved.
    printf '%s\t%s\n' "$TS" "$1" >> "$BATCH"
    count=$((count + 1))
}

flush() {
    [ "$count" -gt 0 ] || { batch_start=""; return 0; }

    # Build the Loki push JSON safely with jq. --raw-input reads each record as
    # a string; split on the FIRST tab using index()+slicing (NO regex builtins,
    # so the base `jq` package works, not just jq-full). jq handles all escaping
    # (quotes, backslashes, control chars, unicode) and emits the ns timestamp
    # as a STRING (Loki 400s on a numeric timestamp).
    if ! jq -cRn --arg job "$JOB" '
            def rec: . as $l
                     | ($l | index("\t")) as $i
                     | [ $l[0:$i], $l[$i+1:] ];
            { streams: [ { stream: { job: $job },
                           values: [ inputs | rec ] } ] }
        ' "$BATCH" > "$PAYLOAD" 2>/dev/null; then
        logger -t loki-shipper "jq failed to build payload; dropping $count line(s)"
        : > "$BATCH"; count=0; batch_start=""; return 0
    fi

    _try=0
    while :; do
        _code=$(curl -s -o /dev/null -w '%{http_code}' \
                    --max-time "$CURL_TIMEOUT" \
                    --connect-timeout "$CONNECT_TIMEOUT" \
                    -K "$CURLCFG" \
                    -H 'Content-Type: application/json' \
                    --data-binary @"$PAYLOAD" \
                    "$LOKI_URL" 2>/dev/null) || _code="000"
        case "$_code" in
            200|204) break ;;                       # 204 = Loki push OK
            *)
                _try=$((_try + 1))
                if [ "$_try" -ge "$MAX_RETRIES" ]; then
                    logger -t loki-shipper "push failed (http=$_code) after ${_try} attempts; dropping $count line(s)"
                    break
                fi
                sleep "$RETRY_SLEEP"
                ;;
        esac
    done

    : > "$BATCH"; count=0; batch_start=""
}

# --- runtime dir + credentials config (/tmp is ramfs; rebuild every start) --
mkdir -p "$RUNDIR"
: > "$BATCH"
# curl reads basic-auth creds from a 0600 config file instead of `-u user:pass`
# so they never appear in `ps`. Rebuilt from env each start; removed on exit.
# Escape backslash then double-quote first — curl config values are double-quoted
# strings, so a special char in the password would otherwise corrupt the creds.
_esc_user=$(printf '%s' "$LOKI_AUTH_USERNAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
_esc_pass=$(printf '%s' "$LOKI_AUTH_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
( umask 077; printf 'user = "%s:%s"\n' "$_esc_user" "$_esc_pass" > "$CURLCFG" )

rm -f "$FIFO"
mkfifo "$FIFO" || { logger -t loki-shipper "cannot create fifo $FIFO; aborting"; exit 1; }

# Open the fifo read-write on fd 3 and keep it open. Because WE hold a writer,
# `read` never sees EOF when logread dies -- it just times out. That lets us use
# read's timeout purely for the time-based flush, and detect logread's death
# separately via `kill -0` (below) so procd respawns us cleanly.
exec 3<>"$FIFO"

logread -f > "$FIFO" &
LR=$!

cleanup() { kill "$LR" 2>/dev/null; exec 3>&- 2>/dev/null; rm -rf "$RUNDIR"; }
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

# --- main loop --------------------------------------------------------------
while :; do
    if IFS= read -r -t "$FLUSH_SECS" line <&3; then
        add_line "$line"
        now=$(date +%s)
        [ -n "$batch_start" ] || batch_start="$now"
        if [ "$count" -ge "$BATCH_MAX" ] || [ $((now - batch_start)) -ge "$FLUSH_SECS" ]; then
            flush
        fi
    else
        # read returned non-zero: a quiet-period timeout OR logread has exited.
        flush                                   # ship whatever was pending
        if ! kill -0 "$LR" 2>/dev/null; then
            logger -t loki-shipper "logread exited; stopping so procd respawns us"
            exit 1
        fi
    fi
done
LOKI_SHIPPER_SH
chmod +x /usr/bin/loki-shipper.sh

# --- procd init service -----------------------------------------------------
cat > /etc/init.d/loki-shipper << 'LOKI_INIT_SH'
#!/bin/sh /etc/rc.common
#
# procd service for the lightweight Loki log shipper (/usr/bin/loki-shipper.sh).

START=99
STOP=10
USE_PROCD=1

start_service() {
    # Loki basic-auth creds -- device-local, off-git, chmod 600. Sourced here so
    # we can hand them to the shipper via procd's per-instance env (procd wipes
    # the ambient environment, so they MUST be injected explicitly).
    [ -f /etc/local-secrets ] && . /etc/local-secrets

    procd_open_instance
    procd_set_param command /usr/bin/loki-shipper.sh
    procd_set_param env \
        LOKI_AUTH_USERNAME="${LOKI_AUTH_USERNAME:-}" \
        LOKI_AUTH_PASSWORD="${LOKI_AUTH_PASSWORD:-}"
    # Respawn if it ever dies (e.g. logread/logd restart makes the shipper exit).
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
LOKI_INIT_SH
chmod +x /etc/init.d/loki-shipper

# --- loki.homelab must resolve from THIS box --------------------------------
# Same gotcha as the S3 backup: a router that doesn't use the home router's
# resolver can't see .homelab names, so every push silently fails. If so, pin
# it in /etc/hosts (preserved across sysupgrade).
if ! nslookup loki.homelab 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address/{print $NF}' | grep -q .; then
  if ! grep -q 'loki.homelab' /etc/hosts 2>/dev/null; then
    echo "WARN: loki.homelab does not resolve — log pushes will fail."
    echo "      Pin it (get the IP from a box that can resolve it):"
    echo "        echo '<loki-ip>  loki.homelab' >> /etc/hosts && /etc/init.d/dnsmasq restart"
  fi
fi

# --- enable + start ---------------------------------------------------------
/etc/init.d/loki-shipper enable
/etc/init.d/loki-shipper start
sleep 3

# --- verify -----------------------------------------------------------------
pgrep -f /usr/bin/loki-shipper.sh >/dev/null \
    && echo "loki-shipper: running" \
    || echo "loki-shipper: NOT running -- check: logread | grep loki-shipper"
logread | grep loki-shipper | tail

# End-to-end (uncomment to run interactively):
# . /etc/local-secrets
# logger -t loki-verify "loki-shipper end-to-end test $(date +%s)"
# sleep 7
# curl -s -G "http://loki.homelab:3100/loki/api/v1/query_range" \
#     -u "$LOKI_AUTH_USERNAME:$LOKI_AUTH_PASSWORD" \
#     --data-urlencode "query={job=\"$(uci -q get system.@system[0].hostname)\"} |= \`loki-verify\`" \
#     | jq '.data.result'
