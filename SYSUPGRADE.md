# Surviving sysupgrades

OpenWrt `sysupgrade` only preserves `/etc/config/*` (UCI) plus a short package-owned
keep-list. **Everything else this repo builds gets wiped**: installed packages, all
kmods (including the wifi driver), the promtail binary + its loader symlinks, the
custom `/usr/bin/*.sh` collectors, the custom `/etc/init.d` services, and the rc.d
enable-symlinks that make them start.

This is the strategy to make an upgrade seamless, plus the daily off-box backup.

## Three layers

| State | Mechanism | Why |
|---|---|---|
| Packages + kmods | Attended Sysupgrade (`owut`) bakes them into the new image | Only path that guarantees kmods (wifi `kmod-mt7916-firmware`, `kmod-tcp-bbr`) come back ABI-matched to the new kernel — a mismatched `.ko` refuses to load and the radios stay dead |
| Small on-device state | `/etc/sysupgrade.conf` backup list | Restores verbatim: collector scripts, init.d services + enable-symlinks, promtail config, secrets, firehol save, crontab |
| Wiped rootfs glue | idempotent provisioner (`/usr/bin/router-provision.sh`) | promtail binary re-fetch + symlinks, ramfs dirs, re-disable odhcpd. **Network-dependent steps run from `rc.local` (post-network), NOT uci-defaults (pre-network)** |

## Packages: Attended Sysupgrade (owut)

```sh
opkg update && opkg install owut ca-bundle wget-ssl openssl-util
owut check                       # confirm target rockchip/armv8 nanopi-r5c + package list
owut upgrade --version 24.10.x   # ASU builds an image with all packages + matched kmods, flashes it
```

`owut` enumerates the live world set via rpcd — never hand-type the package list; that
misses items. Commit a per-router manifest (`packages-<role>.list`, from
`opkg list-installed`) as documentation + the offline fallback:

```sh
opkg install $(grep -v '^#' packages-<role>.list)   # fallback only; needs the matching release feed
```

Never carry old `.ko` files across or list kmods in `sysupgrade.conf` — opkg refuses a
mismatched vermagic. ASU is the only thing that rebuilds them matched.

## `/etc/sysupgrade.conf` manifest

Populated idempotently by `common/09-backup-restore.sh`, which is **self-selecting per
box** — no per-router editing:

- Custom `/usr/bin/*.sh` are enumerated dynamically, so device-local scripts that never
  made it into the repo (e.g. the lab router's `backhaul-*.sh`) are captured too.
- Everything else is a guarded list (`add_keep` skips any path not present), so home-only
  items (firehol init.d + rc.d symlinks, `firehol-ipset.save`, `adguard-creds.conf`) are
  simply absent on lab/repeater and skipped automatically.

Back up the **rc.d enable-symlinks directly** (not via the provisioner) so services are
enabled in the correct START order at first boot — this closes the firehol-set-before-fw4 race:

```
/etc/rc.d/S99promtail  /etc/rc.d/S19firehol-blocklist  /etc/rc.d/K89firehol-blocklist
```

Back up the two promtail loader symlinks directly too (tiny, targets exist in base image):

```
/lib64/ld-linux-aarch64.so.2   /lib/ld-linux-aarch64.so.1
```

**Do NOT** add `/usr/bin/promtail` (93 MB → bloats the ramfs restore tarball, risks a
soft-brick). It is re-fetched by the provisioner.

**Do NOT** rely on `/etc/dnsmasq.conf` being preserved (unverified conffile). Relocate the
`local=/homelab/`, `local=/lan/`, `domain=homelab` directives into
`/etc/dnsmasq.d/homelab.conf` — that path IS preserved and is what dnsmasq's confdir reads.
This is also what keeps `.lan`/`.homelab` from leaking to the ISP resolver after an upgrade.

## The provisioner (`/usr/bin/router-provision.sh`)

Idempotent, re-runnable, no `set -e`. Split by network dependency:

- **Pre-network safe** (call from a `uci-defaults` trigger baked into the image, or by hand):
  recreate the two loader symlinks; `mkdir -p /var/prometheus /tmp/prometheus`;
  `/etc/init.d/promtail enable`; `/etc/init.d/firehol-blocklist enable`;
  `/etc/init.d/odhcpd disable && stop` (the new firmware re-enables it — IPv6-off hygiene).
- **Network-dependent** (must run from `rc.local`, which is preserved and runs *after* netifd —
  NOT from uci-defaults, which runs pre-network and would fail forever):
  re-fetch `/usr/bin/promtail` if missing; `/usr/bin/firehol-refresh.sh &` to warm the blocklist.

The loader symlinks must exist before promtail's `START=99` fires, so keep them in the backup
(above) as the primary path; the provisioner recreating them is belt-and-suspenders.

## Secrets

All real credentials live in `/etc/local-secrets` (chmod 600, git-ignored, listed in
`sysupgrade.conf`). Scripts `. /etc/local-secrets`; the repo ships `common/local-secrets.example`
with dummies. Keep an **off-device** copy — it exists nowhere else, and it holds the backup
decryption passphrase.

## Daily encrypted backup to MinIO

`common/09-backup-restore.sh` installs `/usr/bin/router-backup.sh` (daily cron 04:30):

```
sysupgrade -b  →  openssl aes-256-cbc (passphrase from local-secrets)  →  curl --aws-sigv4 PUT
```

- Same manifest as sysupgrade → the backup is complete iff `sysupgrade.conf` is populated.
- **Client-side encrypted** — the tarball holds every router secret; the bucket only ever
  sees ciphertext, and the passphrase is escrowed off-box.
- Bucket key is read+write+list, **no delete**, bucket versioning on, lifecycle for retention →
  a compromised router can't read secrets (encryption) or destroy history (no-delete + versioning).
- Restore: `/usr/bin/router-restore.sh <object-key>` downloads + decrypts + prints the
  `sysupgrade -r` command (does not auto-apply/reboot).
- **Each device gets its own passphrase** (a leak of one can't decrypt another's backups).
- **DNS gotcha:** a router that doesn't use the home router's resolver can't resolve
  `.homelab` names, so the upload fails silently. The lab router needed
  `echo '172.16.1.69  s3.homelab' >> /etc/hosts` (preserved across sysupgrade). The setup
  script warns if the endpoint host doesn't resolve.

## Upgrade runbook

```sh
owut check                                  # review new version + baked package set
sysupgrade -b /tmp/pre-upgrade.tgz          # snapshot; scp off the box
# ensure sysupgrade.conf lists any newly-added scripts
owut upgrade --version 24.10.x              # builds image w/ packages + matched kmods, flashes
# reboot: backup restored -> rc.local re-fetches promtail + warms blocklist
sh /usr/bin/router-provision.sh             # only if the uci-defaults trigger wasn't baked in
sh <role>/99-diagnostics.sh                 # verify: promtail up, .prom fresh, firehol current, wifi/BBR
```

## Still manual (by design)

- Filling `/etc/local-secrets` per device + keeping the off-device copy.
- One-time setup on each of the three boxes.
- Bare-metal SD rebuild (`common/01`) — that's a reflash, re-runs the numbered scripts.
- Bumping version pins (OpenWrt release in `common/01`, promtail URL in `common/08`).
- Reviewing keep.d-preserved files (`sysctl.conf`, `adguardhome.yaml`) against new upstream
  defaults on a major release bump.
