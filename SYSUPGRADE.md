# Surviving sysupgrades

OpenWrt `sysupgrade` only preserves `/etc/config/*` (UCI) plus a short package-owned
keep-list. **Everything else this repo builds gets wiped**: installed packages, all
kmods (including the wifi driver), the custom `/usr/bin/*.sh` scripts, the custom
`/etc/init.d` services, and the rc.d enable-symlinks that make them start.

This is the strategy to make an upgrade seamless, plus the daily off-box backup.
Target: OpenWrt 25.12.x (kernel 6.12, **apk** package manager — not opkg).

## Three layers

| State | Mechanism | Why |
|---|---|---|
| Packages + kmods | Attended Sysupgrade (`owut`) bakes them into the new image | Only path that guarantees kmods (wifi `kmod-mt7916-firmware`, `kmod-tcp-bbr`) come back ABI-matched to the new kernel — a mismatched `.ko` refuses to load and the radios stay dead |
| Small on-device state | `/etc/sysupgrade.conf` backup list | Restores verbatim: collector scripts, the loki-shipper + firehol services + their enable-symlinks, secrets, firehol save, crontab |
| Wiped rootfs glue | idempotent provisioner (`/usr/bin/router-provision.sh`) | ramfs dirs, service enable-state (rc.d symlinks are wiped even when the init scripts are restored), re-disable odhcpd, warm the firehol blocklist |

There is **no big binary to re-fetch** — log shipping is a plain `logread -f | jq | curl`
script (`/usr/bin/loki-shipper.sh`), so it just rides the backup like any collector.

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
  made it into the repo (e.g. the lab router's `backhaul-*.sh`) — and `loki-shipper.sh` —
  are captured too.
- Everything else is a guarded list (`add_keep` skips any path not present), so home-only
  items (firehol init.d + rc.d symlinks, `firehol-ipset.save`, `adguard-creds.conf`) are
  simply absent on lab/repeater and skipped automatically.

Back up the **rc.d enable-symlinks directly** (not via the provisioner) so services are
enabled in the correct START order at first boot — this closes the firehol-set-before-fw4 race:

```
/etc/rc.d/S99loki-shipper  /etc/rc.d/S19firehol-blocklist  /etc/rc.d/K89firehol-blocklist
```

**Do NOT** rely on `/etc/dnsmasq.conf` being preserved (unverified conffile). Relocate the
`local=/homelab/`, `local=/lan/`, `domain=homelab` directives into
`/etc/dnsmasq.d/homelab.conf` — that path IS preserved and is what dnsmasq's confdir reads.
This is also what keeps `.lan`/`.homelab` from leaking to the ISP resolver after an upgrade.

## The provisioner (`/usr/bin/router-provision.sh`)

Idempotent, re-runnable, no `set -e`. Split by network dependency:

- **Pre-network safe** (call from a `uci-defaults` trigger baked into the image, or by hand):
  `mkdir -p /var/prometheus /tmp/prometheus`; `/etc/init.d/loki-shipper enable`;
  `/etc/init.d/firehol-blocklist enable`; `/etc/init.d/odhcpd disable && stop`
  (the new firmware re-enables it — IPv6-off hygiene).
- **Network-dependent** (must run from `rc.local`, which is preserved and runs *after* netifd —
  NOT from uci-defaults, which runs pre-network and would fail forever):
  `/usr/bin/firehol-refresh.sh &` to warm the blocklist.

## Secrets

All real credentials live in `/etc/local-secrets` (chmod 600, git-ignored, listed in
`sysupgrade.conf`). Scripts `. /etc/local-secrets`; the repo ships `common/local-secrets.example`
with dummies. Holds the MinIO keys, the backup passphrase, and the Loki basic-auth creds the
log shipper reads (`LOKI_AUTH_USERNAME` / `LOKI_AUTH_PASSWORD`, injected into its procd env).
Keep an **off-device** copy — it exists nowhere else.

## Log shipping (`common/08`)

`/usr/bin/loki-shipper.sh` — a ~4KB shell script that pipes `logread -f`, batches lines
(50 or 5s), builds the Loki push JSON with `jq` (safe escaping, ns timestamp as a string),
and POSTs to `loki.homelab:3100` with curl basic-auth from `/etc/local-secrets`. Best-effort:
on a Loki outage it retries then drops (never stalls the pipe). Deps: `curl`, `jq` only.
`loki.homelab` must resolve — a box not using the home router's resolver needs the same
`/etc/hosts` pin as `s3.homelab` (the setup script warns).

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
# reboot: backup restored -> rc.local warms the blocklist; services enabled by the provisioner
sh /usr/bin/router-provision.sh             # only if the uci-defaults trigger wasn't baked in
sh <role>/99-diagnostics.sh                 # verify: loki-shipper up, .prom fresh, firehol current, wifi/BBR
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

Log shipping has no pinned binary any more — it's a plain script (`common/08`). The only
external dependency is that OpenWrt still ships a `jq` with valid-UTF-8 handling (≥1.7;
25.12 ships 1.7.1) and `curl` with `--aws-sigv4` (used by the backup, unrelated to logs).

## Hot-swapping a router onto new hardware

Cloning a running router onto a new box, staged in parallel, then swapped with
minimal downtime. Used for the 25.12 hardware refresh.

**The collision to design around:** stage the new box with its WAN plugged into the
old router's LAN, and that WAN lands inside `172.20.1.0/24` — the exact subnet the
new LAN must eventually own. Taking `172.20.1.254` on `br-lan` while `eth1` is on the
live segment makes the box answer ARP for the running router's IP and hijack the
house network. So: **stage on a throwaway LAN subnet, flip at cutover.**

1. **Stage** with LAN on `192.168.1.1`, WAN on DHCP from the old router. Everything
   else (IoT `172.20.2.254`, homelab `172.20.3.254`, VLANs, routes, firewall, wifi)
   can be configured for real — those don't collide.
2. **Restore from the encrypted backup selectively** — never wholesale. Skip
   `/etc/config/network`'s `macaddr` pins (they're the old NICs) and the LAN IP.
   Build the transfer tar with `--uid 0 --gid 0`, or busybox tar restores your
   workstation's uid and dropbear will reject `authorized_keys` and lock you out.
3. **Services bound to the LAN IP** (AdGuard `bind_hosts` + `http.address`, uhttpd
   `listen_http/https`) must point at the staging IP or they fail to start —
   AdGuard panics in `webAPI.start` on an unbindable address.
4. **Cutover** via `/usr/bin/router-cutover.sh`, which flips the LAN IP, rebinds
   those services, optionally clones the old MACs, and reboots. It has a safety
   interlock that refuses to run while WAN still holds a `172.20.1.x` address.

**MAC cloning** (default on) gets the ISP to hand back the *same* public IP and keeps
downstream ARP caches valid. Only safe because the old box is powered off — never run both.

**It does NOT make the WAN come up by itself.** In practice the ISP link had to be kicked
before a lease was issued: the upstream (ONT/CGNAT DHCP server) holds the previous
session/MAC binding for a while, so a freshly-swapped box sits there with no lease even
with the right MAC. Expect to bounce it:

```sh
ifdown wan; sleep 5; ifup wan          # first try
# still nothing? power-cycle the ONT/modem for ~30s, then ifup wan again
logread | grep udhcpc | tail           # confirm "lease of <ip> obtained"
```

**Cable order at swap:** unplug new WAN from old LAN → run cutover (reboots) → plug
ISP into `eth1`, house LAN/trunk into `eth0` → **bounce the WAN as above** → power off
the old router. Don't panic if the box comes back on its staging LAN IP with a dead WAN
mid-sequence; that's the expected in-between state until the cutover has run *and* the
ISP link is re-established.

**Rollback:** power the new box off and re-plug the old one. Its config is untouched,
and its last encrypted backup is in MinIO.

### 25.12 gotchas found during this swap

- **AdGuard config cannot live in `/etc`.** The 25.12 init refuses
  `/etc/adguardhome.yaml` ("must be stored in its own directory") and silently fails
  to start. It now lives at `/etc/adguardhome/adguardhome.yaml`; `common/06-adblock.sh`
  creates it there and migrates an old one.
- **`wpad-basic-mbedtls` breaks the roaming setup.** Its hostapd supports neither
  802.11r nor `bss_transition`, so the config is rejected and affected radios never
  start. `common/04-wifi-module.sh` swaps in `wpad-mbedtls`.
- **avahi needs a dbus restart** after install, or it exits with a dbus policy error.
- **An empty `/etc/firehol-ipset.save` leaves the ipset uncreated** — run
  `firehol-refresh.sh` once after restoring.
