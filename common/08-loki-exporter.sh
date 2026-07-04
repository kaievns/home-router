#!/bin/sh
#
# Ships logs to the homelab Loki via Grafana Alloy (promtail's supported
# successor; promtail went EOL 2026-03). OpenWrt 25.12 = apk.
#
# There is no 'alloy' apk package in the 25.12 feeds, so we fetch the official
# glibc-linked arm64 binary and reuse the same musl->glibc loader shim promtail
# needed (Alloy is NOT statically linked). The ~130MB binary is deliberately
# NOT in the sysupgrade backup — common/10 re-fetches it post-upgrade.
#
# Bump ALLOY_VER here AND in common/10-provisioner.sh together.
#
# Prereq: LOKI_AUTH_USERNAME / LOKI_AUTH_PASSWORD in /etc/local-secrets (off-git,
# chmod 600). Alloy reads them via sys.env(); the init script injects them.

ALLOY_VER="v1.17.1"
ALLOY_URL="https://github.com/grafana/alloy/releases/download/${ALLOY_VER}/alloy-linux-arm64.zip"

# --- deps (25.12 = apk) -----------------------------------------------------
apk update
apk add unzip

# --- fetch + install the binary --------------------------------------------
# wget needs -O because GitHub redirects to an opaque asset URL.
cd /tmp
wget -O alloy-linux-arm64.zip "$ALLOY_URL"
unzip -o alloy-linux-arm64.zip          # extracts a binary named alloy-linux-arm64
mv alloy-linux-arm64 /usr/bin/alloy
chmod +x /usr/bin/alloy
rm -f alloy-linux-arm64.zip

# --- musl->glibc loader shim (identical to the old promtail hack) -----------
# The official Alloy build is dynamically linked against glibc's
# /lib/ld-linux-aarch64.so.2, which musl doesn't ship, so the binary errors
# "not found" on exec. Symlinking the musl loader in its place is enough.
# NOTE: this is the one thing that can't be verified without real 25.12
# hardware — Alloy is a larger OTel binary than promtail; if `alloy --version`
# fails with a missing-symbol error on first boot, fall back to promtail v2.9.17
# (in git history). Alloy's file/loki components are pure Go, so it's very
# likely fine, but verify: `/usr/bin/alloy --version` then `logread | grep alloy`.
mkdir -p /lib64
ln -sf /lib/ld-musl-aarch64.so.1 /lib64/ld-linux-aarch64.so.2
ln -sf /lib/ld-musl-aarch64.so.1 /lib/ld-linux-aarch64.so.1

# --- config -----------------------------------------------------------------
mkdir -p /etc/alloy
cat > /etc/alloy/config.alloy << 'EOF'
// Ships /var/log/messages and /var/log/kern.log to the homelab Loki.
// Drop-in replacement for the old promtail config:
//   * job label = the box's hostname on BOTH streams (constants.hostname,
//     evaluated at runtime — no stale install-time capture like promtail had)
//   * the two streams are told apart by the `filename` label loki.source.file
//     attaches automatically from __path__ — same as promtail. Identical labels
//     mean existing Loki streams/dashboards keep working, no re-fragmentation.
// Basic-auth creds come from the process environment (the init script sources
// /etc/local-secrets and injects them) — never inlined here.

loki.source.file "system_logs" {
  targets = [
    { __path__ = "/var/log/messages", job = constants.hostname },
    { __path__ = "/var/log/kern.log",  job = constants.hostname },
  ]
  forward_to = [loki.write.homelab.receiver]
}

loki.write "homelab" {
  endpoint {
    url = "http://loki.homelab:3100/loki/api/v1/push"
    basic_auth {
      username = sys.env("LOKI_AUTH_USERNAME")
      password = sys.env("LOKI_AUTH_PASSWORD")
    }
  }
}
EOF

# --- procd init service -----------------------------------------------------
cat > /etc/init.d/alloy << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    # /tmp is ramfs (wiped every boot) — recreate Alloy's storage/WAL dir.
    # Read positions live here; on ramfs they reset each boot. That's fine and
    # matches promtail's old /tmp/positions.yaml: /var/log is ALSO ramfs, so the
    # log files and the positions reset in lockstep — zero duplicate shipping.
    mkdir -p /tmp/alloy

    # Loki basic-auth creds — device-local, off-git, chmod 600.
    [ -f /etc/local-secrets ] && . /etc/local-secrets

    procd_open_instance
    procd_set_param command /usr/bin/alloy run \
        --server.http.listen-addr=127.0.0.1:12345 \
        --storage.path=/tmp/alloy \
        --disable-reporting=true \
        /etc/alloy/config.alloy
    # procd resets the instance env, so pass creds (and Go footprint caps)
    # explicitly. config.alloy reads the creds via sys.env().
    procd_set_param env \
        LOKI_AUTH_USERNAME="$LOKI_AUTH_USERNAME" \
        LOKI_AUTH_PASSWORD="$LOKI_AUTH_PASSWORD" \
        GOMAXPROCS=2 \
        GOMEMLIMIT=128MiB
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x /etc/init.d/alloy

/etc/init.d/alloy enable
/etc/init.d/alloy start
sleep 2

# VERIFY it actually execed (musl shim sanity) + is shipping, not crash-looping
/usr/bin/alloy --version
logread | grep -i alloy | tail
