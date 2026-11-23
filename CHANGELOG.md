# Changelog

Every change to `tailnet-ap`, newest first. Each entry says what changed, why it
changed, and how it was checked. The program prints its own version with
`tailnet-ap version`.

Versions are `MAJOR.MINOR.PATCH`. `1.1.0` is the first release that runs outside
Fedora.

## Unreleased

- **One settings file, `/etc/tailnet-ap.conf`.** Plain `KEY=value` lines, `644`,
  root-owned, no secret (the key stays in `/etc/hostapd/tailnet-ap.psk`). It holds
  `SSID`, `COUNTRY`, `HOSTIP`, `PREFIX`, `HOSTRECORD`, `UP_IF`, `WIFI_IF` and
  `DESKTOP_USER`. At run time a setting is the built-in default, then the file,
  then a non-empty `TAILNET_AP_*` variable for that one run. `load_config` parses
  the file (it is never sourced) from `main`, before interface and DNS detection,
  so sourcing the program still reads nothing from the host. Why: the Desktop
  launcher runs `toggle` through `pkexec`, which clears the environment, so every
  `TAILNET_AP_*` override set before `install` was gone by then.
- **`install` writes the settings file once**, from the built-in defaults plus any
  `TAILNET_AP_*` variable set at that moment. When the file exists it is kept and
  `install` prints `keeping the existing settings`, the same rule as the key.
- **`SSID` has an override, `TAILNET_AP_SSID`.** It was hard-coded.
- **`HOSTRECORD` defaults to empty, and empty writes no `host-record=` line.** The
  default was `raspberry-server,100.116.252.86`, the author's Pi, and the dnsmasq
  drop-in repeated it as a fallback, so every install answered for that host. A
  host that relied on it: put `HOSTRECORD=raspberry-server,100.116.252.86` in
  `/etc/tailnet-ap.conf` and run `sudo tailnet-ap install`. `update` reruns
  `install`, so updating without that line drops the record.
- **Removed `DOMAIN` and `TAILNET_AP_DOMAIN`.** The variable was set and never
  read.
- The `TAILNET_AP_*` variables are now applied in `load_config`, after the file,
  instead of when the program is sourced. The built-in defaults are plain values.
- **`--mode wifi` clients reach the internet on iptables and nft hosts.** The
  masquerade and FORWARD rules named `UP_IF`, the cable, in both modes, so in wifi
  mode on Debian, Ubuntu and Raspberry Pi OS clients reached the tailnet and
  nothing else. `fw_apply` and `fw_remove` now take the uplink: `start_ap_on`
  passes the cable in cable mode and the Wi-Fi in wifi mode, and `stop_ap` drops
  the rules for both, because it cannot know the previous run's mode. firewalld
  was not affected: it masquerades the whole zone.
- **`on` adds the AP subnet to the advertised routes instead of replacing them,
  and `off` withdraws it.** `tailscale set --advertise-routes` replaces the whole
  list, so a host that advertised its LAN or an exit node lost it, and `off` never
  withdrew the AP subnet. Both now read the list from `tailscale debug prefs`
  (`adv_routes`, which `doctor` uses too): `on` sets it plus the AP subnet, `off`
  sets it minus the AP subnet and nothing else. A list that cannot be read is
  left alone, and a missing or logged-out tailscale is one line, not a failed run.
- **One run at a time.** Every command that needs root takes an exclusive `flock`
  on `/run/tailnet-ap.lock` before `main` and stops with a message when another
  run holds it. The lock goes with the process. `update` lets go of it before it
  reruns `install`, which takes it too.
- **`HOSTIP` and `PREFIX` are used everywhere.** The DHCP range, the dnsmasq
  router and DNS options, the advertised route, the sysctl note and the `doctor`
  check were written for `10.42.7.0/24`. `ap_subnet` derives them, keeping the
  range inside the subnet and off `HOSTIP`; the defaults give the same drop-in as
  before. `install` and `on` stop on settings that make no usable subnet.
- **The AP has its own dnsmasq, `tailnet-ap-dnsmasq`, not the system's.** Up to
  1.1.4 `on` and `off` started and stopped the system-wide `dnsmasq.service` and
  `install` left `/etc/dnsmasq.d/tailnet-ap.conf`, which a host's own dnsmasq
  (Pi-hole) reads too, so the AP took over that host's DNS. The unit now runs
  dnsmasq with its own `-C` config, and its own lease file and pid file, and the
  old drop-in is removed on install. `clients` reads the new lease file. The
  config adds `except-interface=lo`: naming an interface makes dnsmasq claim
  loopback as well, and a host that already holds 127.0.0.1:53 would make this
  instance fail to bind and leave the AP with no DNS. `install` warns when the
  system `dnsmasq.service` is enabled or running.
- **`enable` and `disable`: the AP can come back at boot.** Opt-in. `enable`
  writes `tailnet-ap-boot.service`, a oneshot that runs `tailnet-ap boot` (which
  is `on` in mode auto) and refuses, touching nothing, when the AP is already up,
  then enables it. `disable` stops the AP and takes the enablement away without
  removing the file. `status` gained an `at boot` line. Nothing starts at boot
  until `enable` is run, so an existing setup is unchanged.
- **`uninstall [--purge]`.** Undoes `install` and `enable`: `off` first, then the
  units, the NetworkManager drop-in, the dnsmasq config and lease file, the sysctl
  drop-in, the Desktop launcher, the binary, and from the firewalld zone only what
  `install` recorded adding (noted in `/var/lib/tailnet-ap/firewalld-added`).
  Anything it did not add is kept and named, with the command to remove it by
  hand. The Wi-Fi key and the settings file stay unless `--purge`. Only the
  program's own paths are ever removed; anything else is refused and reported.
- **`off` removes its firewall rules.** It never did: `fw_remove` was called only
  from `stop_ap`, which `off` does not call, so iptables and nft kept NAT and
  FORWARD rules for an `ap0` that no longer existed.

Checked: not yet. `tests/run-tests.sh` does not cover `load_config` or the new
`install` step; both need a run on a real host before release. The suite has 117
checks now: the new one runs `start_ap_on` in wifi mode against a stubbed
iptables and checks that the masquerade and FORWARD rules name `wlp3s0`. The
route handling, the lock and `ap_subnet` are not in the suite and need the same
real-host run.

## 1.1.4 - 2026-11-21

- **`tailnet-ap update --test`.** Builds a copy of the installed program with
  `VERSION` bumped to `9.9.9`, then checks `bash -n`, the version parse, the
  `sort -V` comparison, a temporary install, the installed copy's `version`
  output, byte-identity and the no-downgrade rule. It writes only to `/tmp`,
  does not contact GitHub, and cannot touch the installed program. This makes
  the update path testable without cutting a release first.

## 1.1.3 - 2026-11-21

- **`doctor` compares the advertised route to the network address, not the host
  address.** The AP host is `10.42.7.1/24`; the advertised route is
  `10.42.7.0/24`, so the check printed `subnet route none` on a host that was
  advertising it. It now derives `10.42.7.0` from `HOSTIP`.
- **`update` adds a cache-buster to the head-commit lookup** so a check run
  seconds after a push does not read the previous commit's metadata.

## 1.1.2 - 2026-11-21

- **`update` pins the download to the current commit.** The contents API at
  `?ref=main` is cached for up to a minute: `update --check` saw 1.1.0 while
  `main` was 1.1.1. It now reads the head SHA from `/commits/main` and fetches
  `contents/tailnet-ap?ref=<sha>`, a URL that is unique per commit.
- **`doctor` reads `AdvertiseRoutes` as JSON.** The old single-line grep
  reported `subnet route none` on the Pi, which was advertising `0.0.0.0/0`,
  `::/0` and `10.42.7.0/24` across several lines. It now prints the AP subnet
  when it is in the list.

## 1.1.1 - 2026-11-21

Fixes `update` itself.

- **`update` downloads through the GitHub contents API**, not
  `raw.githubusercontent.com`. The raw CDN served the previous commit for several
  minutes after the 1.1.0 push: `update --check` saw the old file and `update`
  installed it, **downgrading** a host. The API returns the current blob
  immediately. Requests carry `Accept: application/vnd.github.raw` and a
  `User-Agent`.
- **`update` refuses a file with no `VERSION` or an older version.** A stale or
  truncated download can no longer overwrite a newer installed program. `--check`
  names the case instead of offering a downgrade.

## 1.1.0 - 2026-11-21

Runs on Raspberry Pi OS, Debian and Ubuntu, not only Fedora. Proven on a
Raspberry Pi 3 Model B (Debian 13, kernel 6.12) with a real Android phone,
while the Pi kept serving nginx, SSH and its tailnet address.

### Added

- **`tailnet-ap update [--check]`** (`do_update`). Downloads `main` from
  `REPO_RAW`, rejects a file that fails `bash -n`, compares its sha256 with the
  installed copy, keeps the old program as `/usr/local/bin/tailnet-ap.bak`, and
  refreshes the configs with the new file. It deliberately does **not** restart
  the AP; `tailnet-ap on` applies new rules. Why: the program is shared and
  will change, and a manual `scp` is how a stale copy survives on a Pi.
- **`tailnet-ap version`** (`do_version`). Prints `VERSION`. Why: `update`
  needs a readable version, and "which build is on this box" was otherwise a
  sha256 comparison.
- **`doctor` reports `accept-routes` and the advertised subnet route.** It
  reads `tailscale debug prefs`; when `RouteAll` is false it prints that this
  device cannot reach AP clients by `10.42.7.x` and the exact fix,
  `tailscale set --accept-routes`. Why: that was the last fault hit by hand and
  the program could not name it. Proven on the Hermes box (`accept-routes
  false`, `subnet route none`) and on the Pi (`accept-routes true`, `subnet
  route 10.42.7.0/24`).

### Portability (the program was Fedora-only)

- **Interface detection** (`detect_ifaces`). Keeps `enp0s31f6` / `wlp3s0` as the
  compiled-in defaults, and swaps in a wired `eth*` / `en*` interface and the
  first real wireless interface when those names are absent. It skips `ap0` by
  name. Why: a Pi is `eth0` / `wlan0`, and `ap0` also carries a `wireless` link,
  so the first version could pick the AP itself as "the radio" and then name
  `ap0` in every `nmcli` call. Proven on Debian (`UP_IF=eth0`) and on the Pi
  with the AP up (`WIFI_IF=wlan0`, not `ap0`).
- **Firewall backends** (`fw_backend`, `fw_apply`, `fw_remove`, `fw_zone`).
  `firewalld` first, then `iptables`, then `nft`, then none. iptables rules are
  checked with `-C` and inserted with `-I`, so they sit ahead of ufw's or the
  distribution's own `FORWARD` policy. The rules go in on `on` and come out on
  `off`. Why: a Pi has no firewalld, and a rule appended behind ufw's default
  `DROP` is a rule that never runs. Proven on the Pi: `iptables -S FORWARD`
  showed four `ap0` rules and `-S INPUT` showed 67/53.
- **nftables fallback** when `iptables` is absent. Own table, deleted and
  recreated so it is idempotent. Not exercised on hardware yet; `doctor` shows
  `firewall nftables` when it is the chosen backend.
- **`country_code` in hostapd** (`COUNTRY`, default `NL`). Why: a Pi can have no
  regulatory country set, and hostapd then refuses the radio. Override with
  `TAILNET_AP_COUNTRY`.
- **NetworkManager is optional.** The `unmanaged-devices` drop-in is written only
  when `nmcli` exists. Cable mode already works without it. Why: a minimal Pi
  install may not run NetworkManager, and an empty `/etc/NetworkManager/conf.d`
  is noise.
- **`hostapd` path from `command -v`**, written into the unit through an
  unquoted heredoc. Why: `/usr/sbin/hostapd` is not universal, and a quoted
  heredoc freezes the wrong path.
- **Preflight in `install`.** `hostapd`, `dnsmasq` and `iw` are checked at the
  top and the error names the right package manager (`apt` or `dnf`). Why: a
  missing `hostapd` otherwise surfaced as a mysterious "hostapd would not
  start" minutes later.
- **`pkg_hint`** in the Tailscale warning. Why: `dnf install tailscale` is the
  wrong instruction on Debian and Ubuntu.
- **DNS upstream detection** (`detect_dns_upstream`). `127.0.0.53` when
  systemd-resolved is listening, else Tailscale's `100.100.100.100`, else the
  first IPv4 nameserver. Why: the Pi has no `127.0.0.53`; `systemd-resolved` is
  inactive and `/etc/resolv.conf` is generated by Tailscale. A hardcoded
  upstream would forward into a dead socket. Proven on the Pi: `dnsmasq
  --test` clean, DNS bound to `10.42.7.1:53`, MagicDNS resolved.
- **Desktop user detection** (`detect_desktop_user`). Owner of the active
  graphical session first, then `SUDO_USER`, then uid 1000, then the current
  user. Why: on the ThinkPad the SSH caller is `hermes` while the desktop is
  `tijnb`'s; `SUDO_USER` alone puts the launcher in the wrong home. On a fresh
  Pi the graphical user is whatever was created first.
- **Domain and host-record are overridable** (`TAILNET_AP_DOMAIN`,
  `TAILNET_AP_HOSTRECORD`). Why: the defaults are this homelab's; a friend
  installing on another tailnet should not inherit them.

### Fixed on the Raspberry Pi, all found by running it

- **The iptables `FORWARD` and `INPUT` rules were never inserted.** The rule
  helper converted a check to an insert with `sed 's/ -C / -I /'`, which does
  not match a rule that **starts** with `-C`; every `FORWARD` and `INPUT` rule
  was checked, failed, and skipped, while the `-t nat` rule landed because it
  has a space before `-C`. Fixed with both anchors:
  `sed -e 's/^-C /-I /' -e 's/ -C / -I /'`. Why it mattered: on a host with a
  `DROP` forward policy the AP would associate and carry nothing.
- **No masquerade to `tailscale0`.** The iptables path only masqueraded to the
  uplink, so a client packet to `100.x` left the Pi with a `10.42.7.x` source on
  the tailnet and was dropped. The firewalld path masquerades the whole zone,
  which is exactly why the ThinkPad worked and the Pi did not. Added
  `-s 10.42.7.0/24 -o tailscale0 -j MASQUERADE`. Proven from a client source on
  the AP: `https://100.88.226.114:8006` returned 200, and the phone's
  `ap0 -> tailscale0` counter climbed to 436 packets.
- **brcmfmac refused a second `ap0`.** On the Pi 3B, stopping hostapd left the
  driver in AP mode (`brcmf_cfg80211_stop_ap ... -52`), and the next `on` failed
  with `could not create the virtual AP interface ap0`. `stop_ap` now brings
  `ap0` down before deleting it, and cable mode retries the create after
  cycling `wlan0` down and up. It does not cycle in wifi mode, where that radio
  is the uplink. Proven by `off` / `on` twice, with hostapd active each time.
- **Interface detection picked `ap0` as the radio.** `ap0` has the same
  `/sys/class/net/<if>/device` symlink as `wlan0`, so the device check did not
  exclude it. Only the name is reliable; `detect_ifaces` now skips `$AP_IF`.
- **The lease file path is distribution-specific.** `clients` read
  `/var/lib/dnsmasq/dnsmasq.leases` (Fedora) and printed no IP on Debian, where
  the file is `/var/lib/misc/dnsmasq.leases`. It now tries `/var/lib/misc`
  first and falls back.
- **Android reported "no internet" while everything else worked.** Two DNS
  faults, in order:
  1. Without `filter-AAAA`, the phone got AAAA records for
     `connectivitycheck.gstatic.com`, tried IPv6 first, and the AP has no IPv6
     route. `filter-AAAA` now keeps clients on IPv4. Proven: an explicit AAAA
     query through `10.42.7.1` returns an empty answer, an A query returns
     `142.251.150.120`.
  2. `dhcp-option=option:domain-search=<tailnet-domain>` made the phone ask for
     `connectivitycheck.gstatic.com.taile8e387.ts.net` and
     `www.google.com.taile8e387.ts.net`, get NXDOMAIN, and mark the network as
     no-internet even though the bare names resolved. The search domain is
     gone; the `host-record` still answers the bare `raspberry-server` name.
     The old lease carries the old option, so the phone must forget and rejoin
     (or reboot) before the fix is visible.

### Changed

- `install` warns when the distribution's own `hostapd.service` is running; a
  second hostapd would fight ours for the radio. Raspberry Pi OS masks that
  unit by default, which is fine; the program's separate
  `tailnet-ap-hostapd.service` is not affected.
- `status` and `install` print the firewall backend instead of assuming
  firewalld.

### Tests

`bash tests/run-tests.sh` runs 116 checks on `lib/tailnet-ap-lib.sh` and the
functions extracted from `tailnet-ap-on.sh`, which is the code the single file
was merged from. It does **not** source the merged file, so `update` and
`doctor` are not covered by the suite. Those were exercised by hand on the Pi:
`version`, `update --check`, a deliberately modified installed copy updated back
to the released file, and `doctor` showing `accept-routes` and the AP subnet.
The Pi was also the integration test: hostapd, dnsmasq, DHCP, DNS, NAT to the
uplink, NAT to `tailscale0`, and `off` / `on` twice.

## 0.1.0 - 2026-11-21

The first single-file program, proven on the ThinkPad T480 (Fedora 45).

- Merged the three-script layout into one `tailnet-ap` with `install`, `on`,
  `off`, `toggle`, `status`, `clients`, `key`, `key set` and `help`.
- `cable` and `wifi` modes (with `a` / `b` kept as aliases), a 10-character PSK,
  and a Desktop launcher.
- Firewalld zone setup for `ap0`, `tailscale0`, masquerade, DHCP and DNS.
- End-to-end proof with the user's phone: DHCP lease, MagicDNS resolution, a
  tailnet peer on port 5000, and normal internet through the laptop.