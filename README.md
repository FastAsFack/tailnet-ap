# tailnet-ap

One program that turns a Fedora laptop into a Wi-Fi access point whose clients
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

- Fedora with NetworkManager, `hostapd`, `dnsmasq` and `firewalld`.
- Tailscale installed and running. The program does **not** install Tailscale.
- A Wi-Fi card that supports AP mode.
- Root for `install`, `on`, `off`, `toggle`, `clients` and `key`.

## Install

```bash
sudo ./tailnet-ap install
```

This writes the static configs, generates a 10-character Wi-Fi key on first run
and keeps it on later runs, installs the program to `/usr/local/bin/tailnet-ap`,
and puts a launcher on the desktop.

## Use

```bash
sudo tailnet-ap on                 # auto: cable if ready, else wifi
sudo tailnet-ap on --mode cable    # cable is the uplink, radio is the AP
sudo tailnet-ap on --mode wifi     # Wi-Fi stays the uplink, AP shares the channel
sudo tailnet-ap off                # stop the AP, leave the uplink alone
sudo tailnet-ap toggle             # on if down, off if up
sudo tailnet-ap status             # what is running
sudo tailnet-ap clients            # who is on the AP, with signal and traffic
sudo tailnet-ap key                # print the Wi-Fi password
sudo tailnet-ap key set 'newpass'  # change it (8 to 63 characters)
tailnet-ap help                    # the list
```

`cable` and `wifi` are the readable names. `a` and `b` still work as aliases.

## The key

The Wi-Fi key is the front door to the tailnet. Anyone who joins the access
point gets the same reach as the laptop. Keep it long and change it when a
device goes missing.

The key lives in `/etc/hostapd/tailnet-ap.psk` and nowhere else. It is never
printed during install. `tailnet-ap key` shows it on demand.

## How the clients reach the tailnet

The AP subnet `10.42.7.0/24` is advertised to the tailnet. The first time, the
route needs approving in the Tailscale admin console. After that it stays
approved. The AP's DNS forwards to the laptop's resolver, so MagicDNS names work
on the clients.

## Tests

```bash
bash tests/run-tests.sh
```

116 checks, no root needed. The suite uses stubs and never touches the real
radio.

## Notes

- The AP is not a guest network. Clients can reach every tailnet host the laptop
  can reach. Treat the Wi-Fi key like a tailnet key.
- On a single radio, `wifi` mode shares the uplink's channel. `cable` mode gives
  the whole radio to the AP.
- A device that loses the AP will usually reconnect on its own when the AP comes
  back.
