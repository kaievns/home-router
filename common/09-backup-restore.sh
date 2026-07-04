#!/bin/sh
#
# Backup + restore machinery: daily encrypted push of the full sysupgrade
# backup to the homelab MinIO (S3) bucket, plus a restore helper, plus the
# /etc/sysupgrade.conf manifest that makes those backups (and in-place
# sysupgrades) actually complete.
#
# See SYSUPGRADE.md for the whole strategy. In short:
#   - `sysupgrade -b` tars /etc/config/* + everything in /etc/sysupgrade.conf,
#     so that manifest is what determines how complete the backup is.
#   - client-side AES encryption (the backup holds every router secret) with a
#     passphrase from /etc/local-secrets, escrowed OFF the device.
#   - upload via curl's native --aws-sigv4 (no extra S3 client binary needed).
#
# Real credentials live ONLY in /etc/local-secrets (chmod 600, git-ignored,
# preserved across sysupgrade). This script ships placeholders.
#
# Idempotent: safe to re-run.

set -e

# openssl CLI for client-side encryption (not in the base image)
apk update
apk add openssl-util

########################################################################
# 1. Secrets file (device-local, off-git). Create a template if absent;
#    never clobber real values already present.
########################################################################
if [ ! -f /etc/local-secrets ]; then
  cat > /etc/local-secrets << 'EOF'
# Device-local secrets — chmod 600, NEVER commit. Preserved across sysupgrade
# because it is listed in /etc/sysupgrade.conf. Keep an OFF-DEVICE copy of the
# BACKUP_PASSPHRASE (e.g. a password manager) — without it the backups are
# unrecoverable, which is exactly when you need them.

# MinIO / S3 (read+write+list key, no delete; bucket has versioning on)
S3_ENDPOINT="http://s3.homelab"
S3_BUCKET="router-backups"
S3_KEY="CHANGE_ME"
S3_SECRET="CHANGE_ME"

# Client-side backup encryption passphrase.
# Generate a strong one: head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1
BACKUP_PASSPHRASE="CHANGE_ME"

# (Consolidate other creds here over time: LOKI_AUTH_*, ADGUARD_*, etc.,
#  and have common/08 + home-router/06,08 source this file instead of
#  carrying inline placeholders.)
EOF
  chmod 600 /etc/local-secrets
  echo "Created /etc/local-secrets template — fill in real values (it is chmod 600)."
else
  echo "/etc/local-secrets already exists — left untouched."
fi

########################################################################
# 2. Backup script (daily via cron)
########################################################################
cat > /usr/bin/router-backup.sh << 'EOF'
#!/bin/sh
# Full config+state backup -> AES-encrypt -> push to MinIO.
[ -f /etc/local-secrets ] || { logger -t backup "no /etc/local-secrets"; exit 1; }
. /etc/local-secrets
[ "$S3_KEY" = "CHANGE_ME" ] && { logger -t backup "local-secrets not filled in"; exit 1; }

HOST=$(uci -q get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
TS=$(date +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d /tmp/backup.XXXXXX) || exit 1
trap 'rm -rf "$STAGE"' EXIT INT TERM

TAR="$STAGE/${HOST}-${TS}.tar.gz"
ENC="$TAR.enc"

# Archive = /etc/config/* + everything listed in /etc/sysupgrade.conf
if ! sysupgrade -b "$TAR" 2>/dev/null; then
  logger -t backup "sysupgrade -b failed"; exit 1
fi

# Client-side encryption (the tarball contains every router secret)
if ! openssl enc -aes-256-cbc -pbkdf2 -salt \
       -in "$TAR" -out "$ENC" -pass pass:"$BACKUP_PASSPHRASE"; then
  logger -t backup "encryption failed"; exit 1
fi

# Upload; object key namespaced by host, sortable by timestamp
OBJ="${HOST}/${HOST}-${TS}.tar.gz.enc"
if curl -sf --max-time 120 --aws-sigv4 "aws:amz:us-east-1:s3" \
     --user "$S3_KEY:$S3_SECRET" -T "$ENC" "$S3_ENDPOINT/$S3_BUCKET/$OBJ"; then
  logger -t backup "uploaded $OBJ ($(wc -c < "$ENC") bytes)"
else
  logger -t backup "upload of $OBJ FAILED"; exit 1
fi
EOF
chmod +x /usr/bin/router-backup.sh

########################################################################
# 3. Restore helper. Downloads + decrypts only; does NOT auto-apply
#    (sysupgrade -r reboots, so a human runs the final step).
########################################################################
cat > /usr/bin/router-restore.sh << 'EOF'
#!/bin/sh
. /etc/local-secrets
OBJ="$1"
if [ -z "$OBJ" ]; then
  echo "usage: $0 <object-key>   e.g. myrouter/myrouter-20260101-043000.tar.gz.enc"
  echo
  echo "available backups in $S3_BUCKET:"
  curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$S3_KEY:$S3_SECRET" \
    "$S3_ENDPOINT/$S3_BUCKET/" | tr '<' '\n' | sed -n 's/^Key>//p'
  exit 1
fi
STAGE=$(mktemp -d /tmp/restore.XXXXXX) || exit 1
ENC="$STAGE/b.enc"; TAR="$STAGE/b.tar.gz"
curl -sf --aws-sigv4 "aws:amz:us-east-1:s3" --user "$S3_KEY:$S3_SECRET" \
  "$S3_ENDPOINT/$S3_BUCKET/$OBJ" -o "$ENC" || { echo "download failed"; exit 1; }
if ! openssl enc -d -aes-256-cbc -pbkdf2 \
       -in "$ENC" -out "$TAR" -pass pass:"$BACKUP_PASSPHRASE"; then
  echo "decrypt failed (wrong BACKUP_PASSPHRASE?)"; exit 1
fi
echo "Decrypted backup: $TAR"
echo "  inspect: tar tzf $TAR | head"
echo "  APPLY (restores config + REBOOTS): sysupgrade -r $TAR"
echo "(staged in $STAGE — ramfs, gone on reboot)"
EOF
chmod +x /usr/bin/router-restore.sh

########################################################################
# 4. Populate /etc/sysupgrade.conf (idempotent) so backups + in-place
#    sysupgrades are COMPLETE. HOME-ROUTER default set — see SYSUPGRADE.md
#    for the lab/repeater swaps.
########################################################################
add_keep() {
  # Only back up paths that actually exist, so `sysupgrade -b`'s tar never
  # errors on a missing file. Paths added later (e.g. the provisioner) get
  # picked up next time this runs.
  if [ -e "$1" ] || [ -L "$1" ]; then
    grep -qxF "$1" /etc/sysupgrade.conf 2>/dev/null || echo "$1" >> /etc/sysupgrade.conf
  else
    echo "  (skip, not present yet: $1)"
  fi
}

# secrets + backup machinery
add_keep /etc/local-secrets
add_keep /usr/bin/router-backup.sh
add_keep /usr/bin/router-restore.sh
add_keep /usr/bin/router-provision.sh

# cron schedule (all monitoring + the backup itself depend on it)
add_keep /etc/crontabs/root

# custom services + their enable-symlinks (restored ENABLED, correct START order,
# so the firehol ipset exists before fw4 loads its ruleset). Guarded, so lab/
# repeater (no firehol) just skip those lines.
add_keep /etc/init.d/alloy
add_keep /etc/rc.d/S99alloy
add_keep /etc/rc.d/K10alloy
add_keep /etc/init.d/firehol-blocklist
add_keep /etc/rc.d/S19firehol-blocklist
add_keep /etc/rc.d/K89firehol-blocklist

# Alloy config + its musl->glibc loader symlinks (tiny; back up, don't recreate).
# NOTE: the ~130MB /usr/bin/alloy binary is deliberately NOT listed — re-fetched
# by common/10. Alloy is glibc-linked like promtail was, so the shim still ships.
add_keep /etc/alloy/config.alloy
add_keep /lib64/ld-linux-aarch64.so.2
add_keep /lib/ld-linux-aarch64.so.1

# runtime state + add-on config
add_keep /etc/firehol-ipset.save
add_keep /etc/known_devices.list
add_keep /etc/adguard-creds.conf
add_keep /etc/avahi/avahi-daemon.conf

# custom /usr/bin shell scripts — enumerate what's ACTUALLY on this box rather
# than a hardcoded list, so device-local additions that never made it into the
# repo (e.g. the lab router's backhaul-*.sh) are captured too. On these boxes
# /usr/bin/*.sh is effectively all our own operational scripts; base/apk
# packages don't drop .sh into /usr/bin here. This makes the manifest correct
# for home/lab/repeater with no per-router editing.
for f in /usr/bin/*.sh; do
  [ -e "$f" ] && add_keep "$f"
done

echo "sysupgrade.conf now backs up:"
grep -v '^#' /etc/sysupgrade.conf | grep -v '^$' | sed 's/^/  /'

########################################################################
# 5. Daily backup cron (04:30 — after the 03:00 firehol refresh)
########################################################################
if ! crontab -l 2>/dev/null | grep -q router-backup.sh; then
  (crontab -l 2>/dev/null; echo "30 4 * * * /usr/bin/router-backup.sh >/dev/null 2>&1") | crontab -
  /etc/init.d/cron restart
  echo "Added daily 04:30 backup cron."
fi

# Warn early if the S3 endpoint host doesn't resolve from THIS box. Routers that
# don't use the home router's resolver (e.g. the lab router, which sits on the
# homelab subnet with its own dnsmasq) can't see .homelab names and uploads fail
# silently. Fix: pin it in /etc/hosts (preserved across sysupgrade).
. /etc/local-secrets 2>/dev/null
EP_HOST=$(echo "${S3_ENDPOINT:-}" | sed -E 's#^https?://##; s#[:/].*##')
if [ -n "$EP_HOST" ]; then
  RESOLVED=$(nslookup "$EP_HOST" 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address/{print $NF}')
  if [ -z "$RESOLVED" ] && ! grep -q "[[:space:]]$EP_HOST\b" /etc/hosts 2>/dev/null; then
    echo
    echo "WARN: '$EP_HOST' does not resolve from this box — uploads will fail."
    echo "      Pin it (get the IP from a box that can resolve it):"
    echo "        echo '<minio-ip>  $EP_HOST' >> /etc/hosts && /etc/init.d/dnsmasq restart"
  fi
fi

cat <<'MSG'

DONE. Next steps:
  1. Fill /etc/local-secrets with the real S3 key/secret and a strong
     BACKUP_PASSPHRASE, then ESCROW the passphrase off the device.
  2. Test end to end:
       /usr/bin/router-backup.sh && logread | grep backup | tail -2
  3. Confirm it landed, then list + restore-check:
       /usr/bin/router-restore.sh          # lists objects
MSG
