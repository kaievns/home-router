#!/bin/sh
#
# Installs the idempotent post-sysupgrade provisioner and wires it to run
# POST-NETWORK from /etc/rc.local.
#
# The provisioner restores the "wiped rootfs glue" that neither UCI-preservation
# nor the backup manifest covers: ramfs dirs, service enable-state (rc.d symlinks
# are wiped even when the init scripts are restored), and the odhcpd-disabled
# posture (the new firmware ships odhcpd enabled). It also warms the firehol
# blocklist. (Log shipping is now a plain script in the backup — no binary to
# re-fetch, so the old promtail/Alloy download + loader-symlink dance is gone.)
#
# Why rc.local and not /etc/uci-defaults: uci-defaults run BEFORE netifd brings
# up the network, so the firehol-refresh HTTPS download would fail on every boot.
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

log() { logger -t provision "$1"; }

# ramfs dirs (/var and /tmp are ramfs — empty every boot)
mkdir -p /var/prometheus /tmp/prometheus

# re-assert service enable-state (rc.d symlinks are wiped even when the init
# scripts survive in the backup). Guarded, so each box only enables what it has.
for svc in loki-shipper firehol-blocklist avahi-daemon; do
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
