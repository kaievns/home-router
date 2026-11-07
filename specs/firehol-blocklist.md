# Firehol blocklist

The main router drops traffic to and from known-bad internet addresses. Every
zone gets this protection, including the work VLAN.

Run the tests with `sh tests/firehol-test.sh`.

## Requirements

- MUST load entries into the nft set `inet fw4 firehol_blocklist`. A legacy
  `ipset` with the same name is a separate kernel object, and fw4 rules never
  read it.
- MUST NOT load an entry that overlaps non-routable space. `firehol_level1`
  ships `172.16.0.0/12`, which holds every internal subnet. It also ships
  `100.64.0.0/10`, which holds the CGNAT WAN gateway and DHCP server.
- MUST apply the rules at the WAN boundary. Sources match on traffic arriving
  from `wan`, and destinations match on traffic leaving to `wan`.
- MUST run the drop rules ahead of the WAN allow rules. The WAN zone already
  rejects everything else, so a later rule has no effect.
- MUST restore the set on every firewall start without network access. fw4 reads
  `/etc/firehol-blocklist.txt` through the set's `loadfile` option.
- MUST NOT reload the firewall during a refresh. A main router reload coincided
  with Moonlight drops. The refresh replaces the set in one nft transaction.
- MUST keep the previous set and list file when a refresh yields fewer than
  1,000 entries, or when nft rejects the load.
- Diagnostics MUST read the nft set. Reading any other store hid this set being
  empty.
