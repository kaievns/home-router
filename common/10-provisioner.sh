#!/bin/sh
#
# Installs the idempotent post-sysupgrade provisioner and wires it to run
# POST-NETWORK from /etc/rc.local.
#
# The provisioner restores the "wiped rootfs glue" that neither UCI-preservation
# nor the backup manifest covers: the promtail binary (too big to back up), the
# musl->glibc loader symlinks, ramfs dirs, service enable-state (rc.d symlinks
# are wiped even when the init scripts are restored), and the odhcpd-disabled
# posture (the new firmware ships odhcpd enabled).
#
# Why rc.local and not /etc/uci-defaults: uci-defaults run BEFORE netifd brings
# up the network, so the promtail HTTPS re-fetch would fail on every boot forever.
# rc.local runs after the network is up and is preserved across sysupgrade.
#
# See SYSUPGRADE.md. Idempotent — safe to re-run.

set -e

########################################################################
# The provisioner itself (role-agnostic; guards on what's present)
########################################################################
cat > /usr/bin/router-provision.sh << 'EOF'
#!/bin/sh
# Idempotent post-sysupgrade / every-boot glue. Runs post-network (rc.local).
# Pinned promtail version — bump here and in common/08 together.
PROMTAIL_URL="https://github.com/grafana/loki/releases/download/v2.9.10/promtail-linux-arm64.zip"

log() { logger -t provision "$1"; }

# ramfs dirs (/var and /tmp are ramfs — empty every boot)
mkdir -p /var/prometheus /tmp/prometheus

# promtail musl->glibc loader symlinks (also in the backup, but cheap to assert;
# must exist before promtail's own START=99 init tries to exec the binary)
if [ -e /lib/ld-musl-aarch64.so.1 ]; then
  mkdir -p /lib64
  ln -sf /lib/ld-musl-aarch64.so.1 /lib64/ld-linux-aarch64.so.2
  ln -sf /lib/ld-musl-aarch64.so.1 /lib/ld-linux-aarch64.so.1
fi

# re-fetch the promtail binary if missing (deliberately NOT in the backup — 93MB)
if [ ! -x /usr/bin/promtail ] && [ -f /etc/promtail/config.yml ]; then
  log "promtail binary missing — fetching"
  if cd /tmp && wget -q -O promtail.zip "$PROMTAIL_URL" && unzip -o promtail.zip >/dev/null 2>&1; then
    mv promtail-linux-arm64 /usr/bin/promtail && chmod +x /usr/bin/promtail && rm -f promtail.zip
    log "promtail fetched"
    /etc/init.d/promtail enable 2>/dev/null
    /etc/init.d/promtail restart 2>/dev/null
  else
    log "promtail fetch FAILED — will retry next boot"
  fi
fi

# re-assert service enable-state (rc.d symlinks are wiped even when the init
# scripts survive in the backup). Guarded, so each box only enables what it has.
for svc in promtail firehol-blocklist avahi-daemon; do
  [ -x /etc/init.d/$svc ] && /etc/init.d/$svc enable 2>/dev/null
done

# re-disable odhcpd — the new firmware ships it enabled, undoing the IPv6-off
# posture (the sysctl kernel disable still holds, but this keeps it clean)
if /etc/init.d/odhcpd enabled 2>/dev/null; then
  /etc/init.d/odhcpd disable 2>/dev/null; /etc/init.d/odhcpd stop 2>/dev/null
  log "odhcpd re-disabled"
fi

# warm the firehol blocklist now (home router only) so fw4's set isn't empty
# until the 3am cron
[ -x /usr/bin/firehol-refresh.sh ] && { /usr/bin/firehol-refresh.sh >/dev/null 2>&1 & }

log "provisioning complete"
EOF
chmod +x /usr/bin/router-provision.sh

########################################################################
# rc.local hook (post-network). Rebuild rather than sed to avoid escaping.
########################################################################
if ! grep -q router-provision.sh /etc/rc.local; then
  HOOK='[ -x /usr/bin/router-provision.sh ] && /usr/bin/router-provision.sh >/tmp/provision.log 2>&1 &'
  grep -v '^exit 0' /etc/rc.local > /tmp/rc.local.new
  echo "$HOOK"  >> /tmp/rc.local.new
  echo "exit 0" >> /tmp/rc.local.new
  mv /tmp/rc.local.new /etc/rc.local
  chmod +x /etc/rc.local
  echo "added rc.local hook"
else
  echo "rc.local hook already present"
fi

# ensure it's captured by the backup manifest
grep -qxF /usr/bin/router-provision.sh /etc/sysupgrade.conf 2>/dev/null || \
  echo /usr/bin/router-provision.sh >> /etc/sysupgrade.conf

echo "provisioner installed. Test now:  sh /usr/bin/router-provision.sh; logread | grep provision | tail"
