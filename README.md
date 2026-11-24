# tailnet-ap

One program that turns a Linux box into a Wi-Fi access point whose clients
reach the whole tailnet, with no software installed on the clients.

A phone or tablet joins the access point like any normal Wi-Fi network. Every
`100.x` address and every MagicDNS name in the tailnet resolves and answers.
Normal internet keeps leaving through the laptop's own uplink.

## What it does

- Creates a virtual AP interface (`ap0`) with `hostapd`.
- Runs `dnsmasq` on that interface for DHCP and DNS, handing out `10.42.7.0/24`.
- Puts the AP interface and `tailscale0` in the firewall zone and masquerades.
- Advertises the AP subnet to the tailnet, so replies can come back.
- Leaves the uplink alone: the cable stays the cable, the Wi-Fi stays the Wi-Fi.

## Requirements

- Linux with `hostapd`, `dnsmasq`, `iw` and a firewall: `firewalld` (Fedora),
  `iptables` (Debian, Ubuntu, Raspberry Pi OS, also behind `ufw`), or `nft` as a
  fallback.
- NetworkManager is used when present. Without it, cable mode still works; Wi-Fi mode
  needs `nmcli` to manage the uplink.
- Tailscale installed and running. The program does **not** install Tailscale.
- A Wi-Fi card that supports AP mode.
- Root for `install`, `uninstall`, `on`, `off`, `toggle`, `enable`, `disable`,
  `clients`, `key` and `update`.

Run `tailnet-ap doctor` on a new machine. It lists the interfaces it found and every
tool that is present or missing, and ends with a verdict: it exits 1 when something
the AP cannot work without is missing or wrong (`hostapd`, `dnsmasq` or `iw`, a radio
that can be an access point, a usable `HOSTIP` and `PREFIX`), and 0 otherwise, so a
script can tell. It also says whether Tailscale is logged in and running, whether
something else already holds port 53 on the AP address, and whether the subnet route
is approved; those are warnings and do not change the exit status. `install` also
picks the desktop user itself: the sudo caller, the first regular user, or you.
Override it with `DESKTOP_USER` (see [Settings](#settings)).

## Ubuntu / Debian

Same as the Pi: `sudo apt install hostapd dnsmasq iptables iw`, then `doctor`, `install`,
`on --mode cable`. With `ufw` active the rules are inserted ahead of ufw's own, so no
extra ufw commands are needed.

## Raspberry Pi

The same file runs on a Pi 3B or newer, and it is proven on a Raspberry Pi 3 Model B
(the 3B, not only the 3B+): Debian 13, kernel 6.12, with a real Android phone. It
detects `eth0` / `wlan0` by itself and uses `iptables` when `firewalld` is not
installed.

```bash
sudo apt update
sudo apt install -y hostapd dnsmasq iptables iw
tailnet-ap doctor                 # hostapd, dnsmasq, iw present; ap capable yes
sudo tailnet-ap install
sudo tailnet-ap on --mode cable
```

Pi notes:
- Use `--mode cable`. The single radio is then free for the AP. `--mode wifi` also
  works, but the AP must share the uplink's channel.
- If the radio refuses to start, set the country: `COUNTRY=NL` in
  `/etc/tailnet-ap.conf`, or `sudo TAILNET_AP_COUNTRY=NL ./tailnet-ap install` the
  first time, which writes it there. `doctor` shows which country is in use.
- The 3B radio is 2.4 GHz only. The 3B+ radio can beacon on 2.4 GHz reliably. If
  5 GHz refuses, stay on 2.4 GHz.

## Install

```bash
sudo ./tailnet-ap install
```

This writes the static configs, generates a 10-character Wi-Fi key on first run
and keeps it on later runs, writes the settings file on first run and keeps it on
later runs, installs the program to `/usr/local/bin/tailnet-ap`, and puts a
launcher on the desktop.

## Settings

The settings live in `/etc/tailnet-ap.conf`: plain `KEY=value` lines, no quotes,
`644` and root-owned. It holds no secret; the Wi-Fi key stays in
`/etc/hostapd/tailnet-ap.psk`. `install` writes it once, from the built-in
defaults plus any `TAILNET_AP_*` variable set at that moment. When the file
already exists, `install` leaves it alone and prints `keeping the existing
settings`, the same rule as for the key; `update`, which reruns `install`, keeps it
too. Edit it with `sudo`.

At run time each setting is taken from, later winning over earlier:

1. the built-in default,
2. `/etc/tailnet-ap.conf`, when it exists,
3. the `TAILNET_AP_*` variable, when it is set and not empty, for that one run only.

An empty value in the file keeps the built-in default. The file is what reaches the
Desktop launcher: it runs `toggle` through `pkexec`, which clears the environment,
so a `TAILNET_AP_*` variable never gets that far.

| Setting | Override | Default | What it does |
|---|---|---|---|
| `SSID` | `TAILNET_AP_SSID` | `thinkpad-tailnet` | The network name the access point broadcasts. |
| `COUNTRY` | `TAILNET_AP_COUNTRY` | `NL` | Regulatory country for hostapd; without one a Pi refuses the radio. |
| `HOSTIP` | none | `10.42.7.1` | Address of `ap0`, the clients' gateway and DNS server. |
| `PREFIX` | none | `24` | Prefix length of the AP subnet. |
| `HOSTRECORD` | `TAILNET_AP_HOSTRECORD` | empty | `NAME,ADDRESS` that dnsmasq answers for a bare name; empty writes no `host-record=` line. |
| `UP_IF` | `TAILNET_AP_UPLINK` | `enp0s31f6` | The uplink interface; detected when it is not on this machine. |
| `WIFI_IF` | `TAILNET_AP_WIFI` | `wlp3s0` | The Wi-Fi radio; detected when it is not on this machine. |
| `DESKTOP_USER` | `TAILNET_AP_USER` | empty | Whose Desktop gets the launcher; empty means detect it. |

`HOSTIP`, `PREFIX`, `HOSTRECORD` and `DESKTOP_USER` are used by `install`, so run
it again after changing them. The DHCP range, the dnsmasq gateway and DNS options
and the advertised route all follow `HOSTIP` and `PREFIX`. The range is the same
share of the subnet as `.50` to `.200` of a `/24`, and never `HOSTIP` itself.
`HOSTIP` must be a host address in its subnet and `PREFIX` 8 to 30; `install`,
`on` and `doctor` say so when they are not. `TAILNET_AP_DNS` (the dnsmasq upstream) and
`TAILNET_AP_ZONE` (the firewalld zone) are not in the file: only `install` reads
them, so pass them to `install` when you need them.

## Use

```bash
sudo tailnet-ap on                 # auto: cable if ready, else wifi
sudo tailnet-ap on --mode cable    # cable is the uplink, radio is the AP
sudo tailnet-ap on --mode wifi     # Wi-Fi stays the uplink, AP shares the channel
sudo tailnet-ap on --mode wifi --move-uplink  # the same, moving the uplink to 2.4 GHz first
sudo tailnet-ap off                # stop the AP, leave the uplink alone
sudo tailnet-ap toggle             # on if down, off if up
sudo tailnet-ap enable             # bring the AP up at every boot
sudo tailnet-ap disable            # stop it, and no longer at boot
sudo tailnet-ap status             # what is running
sudo tailnet-ap clients            # who is on the AP, with signal and traffic
sudo tailnet-ap key                # print the Wi-Fi password
sudo tailnet-ap key set 'newpass'  # change it (8 to 63 characters)
sudo tailnet-ap update             # install the newest release from GitHub
sudo tailnet-ap uninstall          # undo install and enable, keep the key and settings
tailnet-ap doctor                  # check this machine; exit 1 when the AP cannot work
tailnet-ap version                 # what version is installed
tailnet-ap help                    # the list
```

`cable` and `wifi` are the readable names. `a` and `b` still work as aliases.

### `--move-uplink`

In `wifi` mode the AP shares the uplink's channel, and the card only beacons on
2.4 GHz channels 1 to 13 and 5 GHz channels 149 to 165. With the uplink on any
other channel (most 5 GHz networks), `on --mode wifi` stops and says why.
`--move-uplink` is what makes wifi mode work then: `on` copies the live
NetworkManager profile to `tailnet-ap-uplink`, pins the copy to 2.4 GHz, brings it
up by UUID, and starts the AP on the channel it lands on. If the move fails, the
original profile is brought back.

- Put it after `--mode wifi`: only a leading `--mode` sets the mode.
- The Wi-Fi password must be stored in the profile file (`psk=` set, `psk-flags=0`),
  not only in the desktop keyring. Otherwise `on` refuses before it touches the
  link: a copy that cannot log in by itself is how the uplink was lost before.
- `off` leaves the link on the copy, demoted so it does not win the next
  reconnect. `off --handback` moves it back to the normal profile and deletes the
  copy.

## At boot

```bash
sudo tailnet-ap enable     # the AP comes up at every boot
sudo tailnet-ap disable    # stop it, and no longer at boot
```

Nothing starts at boot until `enable` is run, and `enable` needs `install` first.
It writes `tailnet-ap-boot.service`, a oneshot ordered after the network and
`tailscaled`, that runs `tailnet-ap boot`: `on` in mode auto, except that it leaves
an AP that is already up alone. `enable` does not start the AP now; `tailnet-ap on`
does that. `disable` takes the enablement away and runs `off`; the unit file stays,
inert, until `uninstall`. `status` shows an `at boot` line.

## Uninstall

```bash
sudo tailnet-ap uninstall          # keep the Wi-Fi key and the settings
sudo tailnet-ap uninstall --purge  # remove those too
```

`uninstall` runs `off` first, then removes what `install` and `enable` put down:
the three units, the NetworkManager drop-in, the dnsmasq config and lease file,
the hostapd config, the sysctl drop-in, the Desktop launcher, the program and its
`.bak`, and the `tailnet-ap-uplink` copy when it is not the live link. From the
firewalld zone it takes `ap0` and `tailscale0`, and only the masquerade, dhcp and
dns that `install` recorded adding; anything else is kept and named, with the
command to remove it by hand. The key (`/etc/hostapd/tailnet-ap.psk`) and the
settings (`/etc/tailnet-ap.conf`) stay unless `--purge`. It only ever removes the
program's own paths.

## Update

```bash
sudo tailnet-ap update --check    # compare with the newest release, change nothing
sudo tailnet-ap update --test     # prove the update machinery, touch nothing
sudo tailnet-ap update            # install the newest release, keep the key and configs
```

`update` installs only a release, never the head of `main`: it reads the
repository's tags from the GitHub API, takes the highest `vMAJOR.MINOR.PATCH` (by
`sort -V`), and downloads `tailnet-ap` pinned to that tag. When the tag also holds
a `SHA256SUMS` file, the download must match its `tailnet-ap` line, or nothing is
installed; a tag without one is named in one line and the update goes on. With no
release tag at all it stops and says so. It also refuses a file that is not valid
shell, has no `VERSION`, or is older than the installed one. It keeps the old copy
as `/usr/local/bin/tailnet-ap.bak` and refreshes the drop-ins. It does not restart
the AP; `tailnet-ap on` applies new rules. It needs `curl` or `wget`, and
`python3`.

A release is a `vX.Y.Z` tag on a commit whose `SHA256SUMS` was made from that
commit's file: `sha256sum tailnet-ap > SHA256SUMS`. The checksum comes from the
same repository as the file, so it catches a corrupt or mismatched download, not
a compromised repository.

`--test` builds a copy of the installed program with `VERSION=9.9.9`, then
checks the syntax, the version comparison, a temporary install, the installed
copy's `version` output and the no-downgrade rule. It writes only to `/tmp` and
does not contact GitHub.

The full history, with what changed and why, is in
[CHANGELOG.md](CHANGELOG.md).

## The key

The Wi-Fi key is the front door to the tailnet. Anyone who joins the access
point gets the same reach as the laptop. Keep it long and change it when a
device goes missing.

The key lives in `/etc/hostapd/tailnet-ap.psk` and nowhere else. It is never
printed during install. `tailnet-ap key` shows it on demand.

## How the clients reach the tailnet

`on` adds the AP subnet (`10.42.7.0/24` by default) to the routes this host
advertises to the tailnet, keeping the ones it already advertises, and `off`
withdraws it again, and only it. The first time, the
route needs approving in the Tailscale admin console. After that it stays
approved. The AP's DNS forwards to the laptop's resolver, so MagicDNS names work
on the clients.

For the other direction, a tailnet device that must reach an AP client by its
`10.42.7.x` address needs `tailscale set --accept-routes` on **that device**.
`tailnet-ap doctor` shows whether the host it runs on has it on, and prints the
exact fix when it does not. Clients reaching the tailnet do not need it: the AP
masquerades them, so they appear as the AP host.

## Tests

```bash
bash tests/run-tests.sh
```

200 checks, no root needed. The suite sources the program
(`lib/tailnet-ap-lib.sh` is a symlink to it), uses stubs, and never touches the
real radio or the network.

## Notes

- The AP is not a guest network. Clients can reach every tailnet host the laptop
  can reach. Treat the Wi-Fi key like a tailnet key.
- On a single radio, `wifi` mode shares the uplink's channel. `cable` mode gives
  the whole radio to the AP.
- A device that loses the AP will usually reconnect on its own when the AP comes
  back.

## License

MIT, see [LICENSE](LICENSE).
