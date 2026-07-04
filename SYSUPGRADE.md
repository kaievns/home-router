# Surviving sysupgrades

OpenWrt `sysupgrade` only preserves `/etc/config/*` (UCI) plus a short package-owned
keep-list. **Everything else this repo builds gets wiped**: installed packages, all
kmods (including the wifi driver), the Alloy binary + its loader symlinks, the
custom `/usr/bin/*.sh` collectors, the custom `/etc/init.d` services, and the rc.d
enable-symlinks that make them start.

This is the strategy to make an upgrade seamless, plus the daily off-box backup.
Target: OpenWrt 25.12.x (kernel 6.12, **apk** package manager — not opkg).

## Three layers

| State | Mechanism | Why |
|---|---|---|
| Packages + kmods | Attended Sysupgrade (`owut`) bakes them into the new image | Only path that guarantees kmods (wifi `kmod-mt7916-firmware`, `kmod-tcp-bbr`) come back ABI-matched to the new kernel — a mismatched `.ko` refuses to load and the radios stay dead |
| Small on-device state | `/etc/sysupgrade.conf` backup list | Restores verbatim: collector scripts, init.d services + enable-symlinks, Alloy config, secrets, firehol save, crontab |
| Wiped rootfs glue | idempotent provisioner (`/usr/bin/router-provision.sh`) | Alloy binary re-fetch + symlinks, ramfs dirs, re-disable odhcpd. **Network-dependent steps run from `rc.local` (post-network), NOT uci-defaults (pre-network)** |

## Packages: Attended Sysupgrade (owut) on apk

```sh
apk update && apk add owut ca-bundle wget-ssl openssl-util apk-mbedtls
owut check                       # confirm target rockchip/armv8 nanopi-r5c + package list
owut upgrade --version 25.12.x   # ASU builds an image with all packages + matched kmods, flashes it
```

**`apk-mbedtls` is mandatory in the requested set** (openwrt/asu#1084): ASU-built images
omit `/usr/bin/apk` unless it's explicitly included — without it the new firmware has no
package manager.

`owut` enumerates the live world set — never hand-type the package list; that misses items.
apk's authoritative "world" (the packages you added on top of stock) lives in `/etc/apk/world`.
Commit a per-router manifest as documentation + the offline fallback:

```sh
grep -vFxf /rom/etc/apk/world /etc/apk/world | sort > packages-<role>.list   # your delta over stock
apk update && xargs -r apk add < packages-<role>.list                        # fallback restore
```

Never carry old `.ko` files across or list kmods in `sysupgrade.conf` — apk refuses a
mismatched vermagic. ASU is the only thing that rebuilds them matched. And **never
`apk upgrade`** (the OpenWrt cheat sheet forbids it — incomplete conflicts can brick the box);
upgrade via owut only.

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
/etc/rc.d/S99alloy  /etc/rc.d/S19firehol-blocklist  /etc/rc.d/K89firehol-blocklist
```

Back up the two Alloy loader symlinks directly too (tiny, targets exist in base image):

```
/lib64/ld-linux-aarch64.so.2   /lib/ld-linux-aarch64.so.1
```

**Do NOT** add `/usr/bin/alloy` (~130 MB → bloats the ramfs restore tarball, risks a
soft-brick). It is re-fetched by the provisioner.

**Do NOT** rely on `/etc/dnsmasq.conf` being preserved (unverified conffile). Relocate the
`local=/homelab/`, `local=/lan/`, `domain=homelab` directives into
`/etc/dnsmasq.d/homelab.conf` — that path IS preserved and is what dnsmasq's confdir reads.
This is also what keeps `.lan`/`.homelab` from leaking to the ISP resolver after an upgrade.

## The provisioner (`/usr/bin/router-provision.sh`)

Idempotent, re-runnable, no `set -e`. Split by network dependency:

- **Pre-network safe** (call from a `uci-defaults` trigger baked into the image, or by hand):
  recreate the two loader symlinks; `mkdir -p /var/prometheus /tmp/prometheus`;
  `/etc/init.d/alloy enable`; `/etc/init.d/firehol-blocklist enable`;
  `/etc/init.d/odhcpd disable && stop` (the new firmware re-enables it — IPv6-off hygiene).
- **Network-dependent** (must run from `rc.local`, which is preserved and runs *after* netifd —
  NOT from uci-defaults, which runs pre-network and would fail forever):
  re-fetch `/usr/bin/alloy` if missing; `/usr/bin/firehol-refresh.sh &` to warm the blocklist.

The loader symlinks must exist before Alloy's `START=99` fires, so keep them in the backup
(above) as the primary path; the provisioner recreating them is belt-and-suspenders.

## Secrets

All real credentials live in `/etc/local-secrets` (chmod 600, git-ignored, listed in
`sysupgrade.conf`). Scripts `. /etc/local-secrets`; the repo ships `common/local-secrets.example`
with dummies. Holds the MinIO keys, the backup passphrase, and the Loki basic-auth creds Alloy
reads via `sys.env()`. Keep an **off-device** copy — it exists nowhere else.

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
owut check                                  # review new version + baked package set (incl. apk-mbedtls)
sysupgrade -b /tmp/pre-upgrade.tgz          # snapshot; scp off the box
# ensure sysupgrade.conf lists any newly-added scripts
owut upgrade --version 25.12.x              # builds image w/ packages + matched kmods, flashes
# reboot: backup restored -> rc.local re-fetches alloy + warms blocklist
sh /usr/bin/router-provision.sh             # only if the uci-defaults trigger wasn't baked in
sh <role>/99-diagnostics.sh                 # verify: alloy up, .prom fresh, firehol current, wifi/BBR
```

## Still manual (by design)

- Filling `/etc/local-secrets` per device + keeping the off-device copy.
- One-time setup on each box (2 existing nodes + 2 extenders).
- Bare-metal SD rebuild (`common/01`) — that's a reflash, re-runs the numbered scripts.
- Reviewing keep.d-preserved files (`sysctl.conf`, `adguardhome.yaml`) against new upstream
  defaults on a major release bump.

## Version pins

| Pin | Current | Notes |
|---|---|---|
| OpenWrt (`common/01`) | **25.12.5** | Current stable, kernel 6.12, apk. nanopi-r5c image verified present. |
| Grafana Alloy (`common/08` + `common/10`) | **v1.17.1** | promtail's supported successor. **No apk package exists** → downloaded glibc binary + musl loader-shim (like promtail). Keep the version in sync across both files. |

**Alloy musl-shim live-check (the one unverified item):** Alloy is glibc-linked and runs via
the same musl loader symlink promtail used. This is proven for promtail and very likely fine
for Alloy (its file/loki components are pure Go), but it can't be confirmed without real 25.12
hardware. On first boot verify `/usr/bin/alloy --version` execs and `logread | grep alloy` shows
it shipping, not crash-looping. If it fails on a missing glibc symbol, fall back to
**promtail v2.9.17** (in git history) — there is no `gcompat` package on OpenWrt.
