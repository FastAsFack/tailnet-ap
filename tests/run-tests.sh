#!/bin/bash
# run-tests.sh - tests for lib/tailnet-ap-lib.sh, and for the functions of
# tailnet-ap-on.sh that decide whether the link gets dropped. Plain bash, nothing to install.
#
#   tests/run-tests.sh
#
# It sources the library. It never runs tailnet-ap-on.sh or tailnet-ap-off.sh: it reads
# their text, and for cable_ready, restore_uplink and pin_uplink_24 it takes the function's
# definition out of tailnet-ap-on.sh and runs only that, in a subshell. iw and nmcli are
# replaced by stubs that print canned output or play a pretend NetworkManager, and the
# commands that change the machine (systemctl, ip, sleep, pkexec, cp, install) are
# replaced by stubs that refuse and fail the run. Inside a scenario's subshell, sleep
# returns at once, and ip, cat and cp answer for the cable or the scratch directory only.
# Every file it writes goes in a scratch directory under tests/, removed on exit.
#
# Exit status: 0 when every check passes, 1 when any fails, 2 when it will not run.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$HERE/../lib/tailnet-ap-lib.sh
ON=$HERE/../tailnet-ap-on.sh
OFF=$HERE/../tailnet-ap-off.sh

if [ "$EUID" -eq 0 ]; then
    echo "run-tests: run this as a normal user, not root" >&2
    exit 2
fi
for f in "$LIB" "$ON" "$OFF"; do
    [ -r "$f" ] || { echo "run-tests: cannot read $f" >&2; exit 2; }
done
for fn in cable_ready restore_uplink pin_uplink_24; do
    grep -q "^$fn() {\$" "$ON" || { echo "run-tests: cannot find $fn() in $ON" >&2; exit 2; }
done
SCRATCH=$(mktemp -d "$HERE/.scratch.XXXXXX") \
    || { echo "run-tests: cannot make a scratch directory in $HERE" >&2; exit 2; }
trap 'rm -rf -- "$SCRATCH"' EXIT

# ---- reporting ----
PASS=0
FAIL=0
section() { printf '\n== %s ==\n' "$1"; }
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '        %s\n' "$2"; fi
}
# check NAME COMMAND...   passes when COMMAND succeeds
check()  { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
# refute NAME COMMAND...  passes when COMMAND fails
refute() { local n=$1; shift; if "$@"; then bad "$n"; else ok "$n"; fi; }
# same NAME EXPECTED ACTUAL
same()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# has_line TEXT LINE      succeeds when TEXT holds LINE as a whole line
has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }
# answer FUNCTION ARGS...   yes when it succeeds, no when it fails, undefined when there is
# no such function, so a check expecting "no" cannot pass on code that lacks the function
answer() {
    if ! declare -F "$1" >/dev/null; then echo undefined
    elif "$@"; then echo yes
    else echo no; fi
}
# says FUNCTION ARGS...     what it prints, or "undefined" when there is no such function
says() { if declare -F "$1" >/dev/null; then "$@"; else echo undefined; fi; }

# ---- stubs, defined before the library is sourced so nothing real can be reached ----
# Anything that would change the machine is recorded here and fails the run.
refused()   { echo "$*" >> "$SCRATCH/refused"; return 99; }
systemctl() { refused systemctl "$@"; }
ip()        { refused ip "$@"; }
sleep()     { refused sleep "$@"; }
pkexec()    { refused pkexec "$@"; }
cp()        { refused cp "$@"; }
install()   { refused install "$@"; }

IW_INFO=""        # what "iw dev wlp3s0 info" prints in the current check
NM_DEV_STATUS=""  # what "nmcli -t -f DEVICE,STATE dev status" prints
NM_ACTIVE=""      # what "nmcli -t -f NAME,DEVICE con show --active" prints
NM_ACTIVE_UUID="" # what "nmcli -t -f UUID,DEVICE,NAME con show --active" prints
iw() {
    if [ "$*" = "dev $WIFI_IF info" ]; then printf '%s' "$IW_INFO"; return 0; fi
    refused iw "$@"
}
nmcli() {
    case "$*" in
        "-t -f DEVICE,STATE dev status")       printf '%s' "$NM_DEV_STATUS" ;;
        "-t -f NAME,DEVICE con show --active") printf '%s' "$NM_ACTIVE" ;;
        "-t -f UUID,DEVICE,NAME con show --active") printf '%s' "$NM_ACTIVE_UUID" ;;
        *) refused nmcli "$@" ;;
    esac
}
# The cable_ready stub is defined after the library is sourced, further down: the merged
# program defines cable_ready in the same file, so a stub set here would be overwritten.

# ---- running functions of tailnet-ap-on.sh against a pretend NetworkManager ----
# from_on NAME: define function NAME from its text in tailnet-ap-on.sh, from "NAME() {" to
# the next "}" in column 1. Only that text is evaluated, and only inside a scenario's
# subshell, so the definition goes away with it. The script itself never runs.
from_on() { eval "$(sed -n "/^$1() {\$/,/^}\$/p" "$ON")"; }

HOME_UUID=0b6c2f1e-8d2a-4c39-9a51-3e7d1c5f0a11   # HomeNet, the normal profile
COPY_UUID=7f3e9c2d-1b4a-4e6f-8c0d-5a2b9e1f3c22   # the 2.4 GHz copy
nm_uuid() { if [ "$1" = HomeNet ]; then echo "$HOME_UUID"; else echo "$COPY_UUID"; fi; }

# pretend_nm LIVE COPY: replace nmcli and sleep, in the calling subshell, with a pretend
# NetworkManager. Its state:
#   LIVE    the profile up on wlp3s0, empty when wlp3s0 is disconnected
#   COPY    "absent", or the copy's autoconnect/priority, e.g. yes/100
#   PICK    what "nmcli dev connect" brings up: the copy, because NetworkManager picks by
#           priority and then by last use (audit L2)
#   NOAUTH  profiles that cannot log in, because their password is only in the keyring
#   BLANK   yes: "con show --active" prints nothing although wlp3s0 is connected
#   TRIED   every profile NetworkManager was asked to bring up, in order
#   DROPS   how many times a live link was taken down
# Reads answer from the state. Calls that change something change the state the way
# NetworkManager would. Any other nmcli call is refused and fails the run.
pretend_nm() {
    LIVE=$1 COPY=$2 PICK=$UPLINK_CON NOAUTH="" BLANK=no TRIED="" DROPS=0
    sleep() { :; }
    nm_down() { if [ -n "$LIVE" ]; then DROPS=$((DROPS + 1)); LIVE=""; fi; }
    # activating a profile on wlp3s0 first takes down whatever is on it
    nm_up() {
        nm_down
        TRIED=${TRIED:+$TRIED,}$1
        case " $NOAUTH " in *" $1 "*) return 4 ;; esac
        LIVE=$1
    }
    nm_modify_copy() {
        [ "$COPY" != absent ] || return 10
        local ac=${COPY%/*} prio=${COPY#*/}
        while [ $# -ge 2 ]; do
            case $1 in
                connection.autoconnect) ac=$2 ;;
                connection.autoconnect-priority) prio=$2 ;;
            esac
            shift 2
        done
        COPY=$ac/$prio
    }
    nmcli() {
        case "$*" in
            "-t -f DEVICE,STATE dev status")
                if [ -n "$LIVE" ]; then echo "$WIFI_IF:connected"; else echo "$WIFI_IF:disconnected"; fi ;;
            "-t -f DEVICE,STATE,CONNECTION dev status")
                if [ -n "$LIVE" ]; then echo "$WIFI_IF:connected:$LIVE"; else echo "$WIFI_IF:disconnected:"; fi ;;
            "-t -f NAME,DEVICE con show --active")
                [ -z "$LIVE" ] || [ "$BLANK" = yes ] || echo "$LIVE:$WIFI_IF" ;;
            "-t -f UUID,DEVICE con show --active")
                [ -z "$LIVE" ] || [ "$BLANK" = yes ] || echo "$(nm_uuid "$LIVE"):$WIFI_IF" ;;
            "-t -f UUID,DEVICE,NAME con show --active")
                [ -z "$LIVE" ] || [ "$BLANK" = yes ] || echo "$(nm_uuid "$LIVE"):$WIFI_IF:$LIVE" ;;
            "-t -f NAME con show")
                echo HomeNet; [ "$COPY" = absent ] || echo "$UPLINK_CON" ;;
            "dev disconnect $WIFI_IF") nm_down ;;
            "dev connect $WIFI_IF")
                # Measured on the real machine 21 Nov 2026: with both profiles offering the
                # same SSID, "dev connect" brought up the ORIGINAL, not the copy, whatever
                # the copy's priority was. Autoconnect is not deterministic here, so the
                # pin must activate the copy by uuid instead of relying on this.
                nm_up HomeNet ;;
            "con up uuid $HOME_UUID"|"con up uuid $HOME_UUID ifname $WIFI_IF") nm_up HomeNet ;;
            "con up uuid $COPY_UUID"|"con up uuid $COPY_UUID ifname $WIFI_IF") nm_up "$UPLINK_CON" ;;
            # the fresh-copy path activates the uuid it just generated, so match any other uuid
            "con up uuid "*" ifname $WIFI_IF") nm_up "$UPLINK_CON" ;;
            "-g connection.uuid con show $UPLINK_CON") echo "$COPY_UUID" ;;
            "con modify $UPLINK_CON "*) shift 3; nm_modify_copy "$@" ;;
            "con delete $UPLINK_CON")
                [ "$COPY" != absent ] || return 10
                if [ "$LIVE" = "$UPLINK_CON" ]; then nm_down; fi
                COPY=absent ;;
            "con reload")
                # a copy written to disk becomes known, with the settings in its file
                if [ "$COPY" = absent ] && [ -f "$NMDIR/$UPLINK_CON.nmconnection" ]; then
                    COPY=$(awk -F= '$1 == "autoconnect" { a = ($2 == "false" ? "no" : "yes") }
                                    $1 == "autoconnect-priority" { p = $2 }
                                    END { print (a ? a : "yes") "/" (p ? p : 0) }' \
                           "$NMDIR/$UPLINK_CON.nmconnection")
                fi ;;
            *) refused nmcli "$@" ;;
        esac
    }
}
# world STATUS: one line with what a scenario left behind
world() {
    printf 'rc=%s live=%s tried=%s drops=%s copy=%s' \
        "$1" "${LIVE:-none}" "${TRIED:-none}" "$DROPS" "$COPY"
}

# ---- load ----
section "loading the library"
same "sourcing it prints nothing" "" "$(. "$LIB" 2>&1)"
TAILNET_AP_LIB_LOADED=no
. "$LIB"
same "sourcing it reaches the last line" yes "$TAILNET_AP_LIB_LOADED"

# The program defines the real cable_ready; this one answers $CABLE and counts calls.
# It has to be set after the source, or the program's own definition wins.
CABLE=no
CABLE_CALLS=0
cable_ready() { CABLE_CALLS=$((CABLE_CALLS + 1)); [ "$CABLE" = yes ]; }

mismatch=""
for pair in SSID=thinkpad-tailnet HOSTIP=10.42.7.1 PREFIX=24 UP_IF=enp0s31f6 \
            WIFI_IF=wlp3s0 AP_IF=ap0 PSKFILE=/etc/hostapd/tailnet-ap.psk \
            NM_CON=tailnet-ap UPLINK_CON=tailnet-ap-uplink HOSTAPD_UNIT=tailnet-ap-hostapd \
            NMDIR=/etc/NetworkManager/system-connections \
            HOSTAPD_CONF=/etc/hostapd/tailnet-ap.conf; do
    name=${pair%%=*}
    [ "${!name:-}" = "${pair#*=}" ] || mismatch="$mismatch [$name=${!name:-}]"
done
same "the names have the values the scripts used before the move" "" "$mismatch"

# ---- ap_capable ----
section "ap_capable: the channels this card can beacon on"
for ch in 1 6 13 149 165; do check "channel $ch is beaconable" ap_capable "$ch"; done
# 14 was asserted beaconable here before R15; 0, 14 and above 165 were all let through
for ch in 0 14 15 36 44 48 132 148 166 169 173 177; do
    refute "channel $ch is not beaconable" ap_capable "$ch"
done
refute "no channel at all is not beaconable" ap_capable ""

# ---- channel reader ----
section "ch_of: reading the uplink channel from iw"
# a typical "iw dev wlp3s0 info" for a connected station, around the given channel line
iw_info() {
    printf 'Interface wlp3s0\n\tifindex 3\n\twdev 0x1\n\taddr 3c:6a:a7:00:00:01\n'
    printf '\tssid HomeNet\n\ttype managed\n\twiphy 0\n%s\ttxpower 22.00 dBm\n' "$1"
}
IW_INFO=$(iw_info $'\tchannel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz\n')
same "2.4 GHz uplink on channel 6" 6 "$(ch_of)"
check "  and the AP can share it" ap_capable "$(ch_of)"
IW_INFO=$(iw_info $'\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz\n')
same "5 GHz uplink on channel 36" 36 "$(ch_of)"
refute "  and the AP cannot share it: the refusal gate" ap_capable "$(ch_of)"
IW_INFO=$(iw_info $'\tchannel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz\n')
same "5 GHz uplink on channel 149" 149 "$(ch_of)"
check "  and the AP can share it" ap_capable "$(ch_of)"
IW_INFO=$(iw_info "")
same "not associated: no channel" "" "$(ch_of)"
refute "  and that is not beaconable either" ap_capable "$(ch_of)"

# ---- hostapd config ----
section "hostapd config: hw_mode follows the channel (hw_mode=bg shipped once)"
PSK_T=test-passphrase-123
for ch in 1 6 11 13 14; do
    same "channel $ch (2.4 GHz) gives hw_mode=g" hw_mode=g \
        "$(hostapd_conf "$ch" "$PSK_T" | grep '^hw_mode=')"
done
for ch in 149 153 157 161 165; do
    same "channel $ch (5 GHz) gives hw_mode=a" hw_mode=a \
        "$(hostapd_conf "$ch" "$PSK_T" | grep '^hw_mode=')"
done

section "hostapd config: the lines that must always be there"
missing=""
for ch in 1 6 11 13 14 149 153 157 161 165; do
    conf=$(hostapd_conf "$ch" "$PSK_T")
    for line in interface=ap0 "wpa_passphrase=$PSK_T" rsn_pairwise=CCMP "channel=$ch"; do
        has_line "$conf" "$line" || missing="$missing [channel $ch lacks $line]"
    done
    if has_line "$conf" hw_mode=bg; then missing="$missing [channel $ch has hw_mode=bg]"; fi
done
same "every channel: interface=ap0, wpa_passphrase, rsn_pairwise=CCMP, its channel=, no bg" \
    "" "$missing"

odd='a b\t$HOME "q" '\''x'\'' \n end'
same "the passphrase is written as given, no escapes or expansion" \
    "wpa_passphrase=$odd" "$(hostapd_conf 6 "$odd" | grep '^wpa_passphrase=')"

# The whole file, as the pre-refactor writer produced it for these inputs.
GOLDEN_6='# Rewritten by tailnet-ap-on.sh on every start: the channel follows the uplink.
interface=ap0
driver=nl80211
country_code=NL
ssid=thinkpad-tailnet
hw_mode=g
channel=6
ieee80211n=1
ieee80211ac=0
wpa=2
wpa_passphrase=test-passphrase-123
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
auth_algs=1
ignore_broadcast_ssid=0'
GOLDEN_149='# Rewritten by tailnet-ap-on.sh on every start: the channel follows the uplink.
interface=ap0
driver=nl80211
country_code=NL
ssid=thinkpad-tailnet
hw_mode=a
channel=149
ieee80211n=1
ieee80211ac=0
wpa=2
wpa_passphrase=test-passphrase-123
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
auth_algs=1
ignore_broadcast_ssid=0'
same "channel 6: the whole file is unchanged by the refactor" "$GOLDEN_6" "$(hostapd_conf 6 "$PSK_T")"
same "channel 149: the whole file is unchanged by the refactor" "$GOLDEN_149" "$(hostapd_conf 149 "$PSK_T")"

HOSTAPD_CONF=$SCRATCH/tailnet-ap.conf    # never /etc in a test
written=""
write_hostapd_conf 149 "$PSK_T"
IFS= read -r -d '' written < "$HOSTAPD_CONF"
same "write_hostapd_conf writes that file, ending in a newline" "$GOLDEN_149"$'\n' "$written"
same "write_hostapd_conf leaves it readable by root only" 600 "$(stat -c %a "$HOSTAPD_CONF")"

# ---- argument parsing ----
section "tailnet-ap-on.sh arguments"
parsed() {
    ( parse_args "$@" && printf 'mode=%s move-uplink=%s toggle=%s' "$MODE" "$MOVE_UPLINK" "$TOGGLE" ) 2>&1
}
shown() { if [ $# -eq 0 ]; then echo "(no arguments)"; else echo "$*"; fi; }
# accepts EXPECTED ARGS...
accepts() {
    local want=$1 out st; shift
    out=$(parsed "$@"); st=$?
    if [ "$st" -eq 0 ] && [ "$out" = "$want" ]; then ok "accepts $(shown "$@"): $want"
    else bad "accepts $(shown "$@")" "expected [$want] and status 0, got [$out] and status $st"; fi
}
# rejects ARGS...   exits non-zero with die's message about the first argument
rejects() {
    local out st
    out=$(parsed "$@"); st=$?
    if [ "$st" -ne 0 ] && [ "$out" = "tailnet-ap: unknown argument: $1" ]; then
        ok "rejects $(shown "$@"): status $st, \"$out\""
    else bad "rejects $(shown "$@")" "expected die's message and status 1, got [$out] and status $st"; fi
}
accepts "mode=auto move-uplink=no toggle=no"
accepts "mode=a move-uplink=no toggle=no"   --mode a
accepts "mode=b move-uplink=no toggle=no"   --mode b
accepts "mode=auto move-uplink=no toggle=yes" --toggle
accepts "mode=auto move-uplink=yes toggle=no" --move-uplink
accepts "mode=b move-uplink=yes toggle=no"  --mode b --move-uplink
accepts "mode=auto move-uplink=no toggle=no" --mode
# pinned on purpose: only a leading --mode sets the mode, as before the refactor
accepts "mode=auto move-uplink=yes toggle=no" --move-uplink --mode b
rejects --bogus
rejects -h
rejects --mode=b
rejects b

section "tailnet-ap-off.sh arguments"
off_parsed() { ( parse_off_args "$@" && printf 'handback=%s' "$HANDBACK" ) 2>&1; }
same "--handback asks for the handback" handback=yes "$(off_parsed --handback)"
same "no arguments: no handback" handback=no "$(off_parsed)"
same "an unknown argument is ignored, as before" handback=no "$(off_parsed --bogus)"
same "only the first argument counts, as before" handback=no "$(off_parsed --bogus --handback)"

# ---- mode decision ----
section "mode decision"
# decided CABLE REQUESTED: print "MODE, cable checked N times", or die's message
decided() {
    ( CABLE=$1; CABLE_CALLS=0
      decide_mode "$2" && printf '%s, cable checked %s times' "$MODE" "$CABLE_CALLS" ) 2>&1
}
same "auto with a live cable picks cable" "cable, cable checked 1 times" "$(decided yes auto)"
same "auto without a live cable picks wifi" "wifi, cable checked 1 times" "$(decided no auto)"
same "cable stays cable without checking the cable" "cable, cable checked 0 times" "$(decided no a)"
same "wifi stays wifi without checking the cable" "wifi, cable checked 0 times" "$(decided yes b)"
out=$(decided yes x); st=$?
if [ "$st" -ne 0 ] && [ "$out" = "tailnet-ap: mode must be cable, wifi or auto" ]; then
    ok "an unknown mode exits with status $st: \"$out\""
else bad "an unknown mode is refused" "got [$out] and status $st"; fi
out=$( ( parse_args --mode x && decide_mode "$MODE" ) 2>&1 ); st=$?
same "--mode x: parsed, then refused by the mode decision" \
    "1 tailnet-ap: mode must be cable, wifi or auto" "$st $out"

# ---- NetworkManager readers ----
section "NetworkManager readers (the guards against deleting the live uplink use these)"
NM_DEV_STATUS=$'enp0s31f6:unavailable\nwlp3s0:connected\np2p-dev-wlp3s0:disconnected\nlo:connected (externally)\n'
check "wifi_connected: wlp3s0 connected" wifi_connected
NM_DEV_STATUS=$'wlp3s0:disconnected\n'
refute "wifi_connected: wlp3s0 disconnected" wifi_connected
NM_DEV_STATUS=$'wlp3s0:connecting (getting IP configuration)\n'
refute "wifi_connected: wlp3s0 still connecting" wifi_connected
NM_DEV_STATUS=$'wlp3s0:unavailable\np2p-dev-wlp3s0:connected\n'
refute "wifi_connected: only p2p-dev-wlp3s0 connected" wifi_connected
NM_DEV_STATUS=""
refute "wifi_connected: nmcli printed nothing" wifi_connected

NM_ACTIVE=$'Wired connection 1:enp0s31f6\ntailnet-ap-uplink:wlp3s0\nlo:lo\n'
same "active_con names the 2.4 GHz copy while the machine rides it" "$UPLINK_CON" "$(active_con)"
NM_ACTIVE=$'Wired connection 1:enp0s31f6\nHomeNet:wlp3s0\n'
same "active_con names the normal profile" HomeNet "$(active_con)"
NM_ACTIVE=$'Wired connection 1:enp0s31f6\ntailnet-ap:ap0\n'
same "active_con is empty when nothing is on wlp3s0" "" "$(active_con)"

# ---- R1 ----
section "R1: --move-uplink only drops the link for a copy that can log in by itself"
KF=$SCRATCH/keyfiles
mkdir "$KF"
# keyfile FILE ID UUID [WIFI-SECURITY-LINE...]: write a wi-fi keyfile to $KF/FILE
keyfile() {
    local f=$KF/$1 id=$2 uuid=$3; shift 3
    { printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' "$id" "$uuid"
      printf '[wifi]\nmode=infrastructure\nssid=HomeNet\n\n[wifi-security]\nkey-mgmt=wpa-psk\n'
      if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi
      printf '\n[ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n'
    } > "$f"
}
keyfile stored   HomeNet "$HOME_UUID" psk=correct-horse-battery
keyfile flags0   HomeNet "$HOME_UUID" psk=correct-horse-battery psk-flags=0
keyfile spacedok HomeNet "$HOME_UUID" "psk = correct-horse-battery"
keyfile keyring  HomeNet "$HOME_UUID" psk-flags=1
keyfile both     HomeNet "$HOME_UUID" psk=correct-horse-battery psk-flags=1
keyfile notsaved HomeNet "$HOME_UUID" psk-flags=2
keyfile spaced   HomeNet "$HOME_UUID" "psk = correct-horse-battery" "psk-flags = 1"
keyfile empty    HomeNet "$HOME_UUID" psk=
keyfile nopsk    HomeNet "$HOME_UUID"
keyfile copy-keyring "$UPLINK_CON" "$COPY_UUID" psk-flags=1

same "psk_stored: psk= in the file, no psk-flags" yes "$(answer psk_stored "$KF/stored")"
same "psk_stored: psk= in the file, psk-flags=0" yes "$(answer psk_stored "$KF/flags0")"
same "psk_stored: spaces around = are read the way GKeyFile reads them" \
    yes "$(answer psk_stored "$KF/spacedok")"
same "psk_stored: keyring only, as NetworkManager writes it (psk-flags=1, no psk=)" \
    no "$(answer psk_stored "$KF/keyring")"
same "psk_stored: psk= but psk-flags=1, so NetworkManager asks the keyring anyway" \
    no "$(answer psk_stored "$KF/both")"
same "psk_stored: psk-flags=2, never saved" no "$(answer psk_stored "$KF/notsaved")"
same "psk_stored: psk-flags = 1 written with spaces" no "$(answer psk_stored "$KF/spaced")"
same "psk_stored: psk= with nothing after it" no "$(answer psk_stored "$KF/empty")"
same "psk_stored: no psk= at all (open or enterprise network)" no "$(answer psk_stored "$KF/nopsk")"
same "psk_stored: no such file" no "$(answer psk_stored "$KF/missing")"

# after_pin NOAUTH HOME-KEYFILE [COPY-KEYFILE]: run pin_uplink_24 from tailnet-ap-on.sh with
# HomeNet up (on a 5 GHz channel) and its keyfile in a scratch $NMDIR. With COPY-KEYFILE the
# copy already exists from an earlier run, demoted the way tailnet-ap-off.sh leaves it.
# NOAUTH goes to the pretend NetworkManager. A copy that connects lands on channel 6.
# Prints the world and the copy file's fate on one line, then what was said on stderr,
# with the scratch $NMDIR shown as NMDIR.
after_pin() {
    ( NMDIR=$(mktemp -d "$SCRATCH/nmdir.XXXXXX")
      ERR=$(mktemp "$SCRATCH/stderr.XXXXXX")
      command cp "$2" "$NMDIR/HomeNet.nmconnection"
      if [ -n "${3:-}" ]; then
          command cp "$3" "$NMDIR/$UPLINK_CON.nmconnection"
          pretend_nm HomeNet no/0
      else
          pretend_nm HomeNet absent
      fi
      NOAUTH=$1
      cp() { case "$*" in "-f $NMDIR/"*" $NMDIR/"*) command cp "$@" ;; *) refused cp "$@" ;; esac; }
      IW_INFO=$(iw_info $'\tchannel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz\n')
      from_on pin_uplink_24
      trap 'st=$?; world "$st"
            if [ -e "$NMDIR/$UPLINK_CON.nmconnection" ]; then echo " copy-file=kept"
            else echo " copy-file=gone"; fi
            sed "s|$NMDIR|NMDIR|g" "$ERR"' EXIT
      pin_uplink_24 2>"$ERR" )
}
out=$(after_pin "$UPLINK_CON" "$KF/keyring")
same "keyring-only profile, new copy: stops with the link untouched and the copy gone" \
    "rc=1 live=HomeNet tried=none drops=0 copy=absent copy-file=gone" "$(sed -n 1p <<<"$out")"
same "  and says why, naming the profile to fix" \
    "tailnet-ap: not moving the uplink: the wi-fi password is not stored in NMDIR/HomeNet.nmconnection, so a copy of it could not log in without the desktop keyring. Store it there first (psk= set, psk-flags=0)." \
    "$(sed -n 2p <<<"$out")"
out=$(after_pin "$UPLINK_CON" "$KF/stored" "$KF/copy-keyring")
same "keyring-only copy left by an earlier run: stops with the link and the copy untouched" \
    "rc=1 live=HomeNet tried=none drops=0 copy=no/0 copy-file=kept" "$(sed -n 1p <<<"$out")"
same "  and says why" \
    "tailnet-ap: not moving the uplink: the wi-fi password is not stored in NMDIR/$UPLINK_CON.nmconnection, so it could not log in without the desktop keyring. Store it there first (psk= set, psk-flags=0)." \
    "$(sed -n 2p <<<"$out")"
# the other direction, so the guard cannot just refuse everything (passes before the fix too)
out=$(after_pin "" "$KF/stored")
same "password stored in the profile: the move still goes ahead and lands on channel 6" \
    "rc=0 live=$UPLINK_CON tried=$UPLINK_CON drops=1 copy=yes/100 copy-file=kept" "$out"

# ---- R2 ----
section "R2: restore_uplink never retries the copy, never drops a working link, demotes the copy"
# what tailnet-ap-on.sh records before the move, for restore_uplink to bring back
NM_ACTIVE_UUID="aaaa-1:enp0s31f6:Wired connection 1"$'\n'"$HOME_UUID:wlp3s0:HomeNet"$'\n'
same "orig_uuid: HomeNet is live, so that is the profile to go back to" \
    "$HOME_UUID" "$(says orig_uuid)"
NM_ACTIVE_UUID="$COPY_UUID:wlp3s0:$UPLINK_CON"$'\n'
same "orig_uuid: the copy is live, so there is nothing to go back to" "" "$(says orig_uuid)"
NM_ACTIVE_UUID="$HOME_UUID:wlp3s0:Cafe\\:Guest"$'\n'
same "orig_uuid: a name with a ':' in it, which nmcli escapes" "$HOME_UUID" "$(says orig_uuid)"
NM_ACTIVE_UUID=""
same "orig_uuid: nmcli printed nothing" "" "$(says orig_uuid)"

# after_restore LIVE COPY ORIG [NAME=VALUE...]: run restore_uplink from tailnet-ap-on.sh
# with LIVE up on wlp3s0 (empty: disconnected), the copy at COPY (autoconnect/priority, as
# the move left it), ORIG_UUID=ORIG, and any NAME=VALUE set in the pretend NetworkManager.
# Prints the world it leaves.
after_restore() {
    ( pretend_nm "$1" "$2"; ORIG_UUID=$3; shift 3
      for kv in "$@"; do printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
      from_on restore_uplink
      restore_uplink; world $? )
}
same "move failed, wi-fi down: HomeNet comes back by UUID, the copy is not tried, then deleted" \
    "rc=0 live=HomeNet tried=HomeNet drops=0 copy=absent" \
    "$(after_restore "" yes/100 "$HOME_UUID")"
same "move failed, NetworkManager already back on HomeNet: that link is left alone" \
    "rc=0 live=HomeNet tried=none drops=0 copy=absent" \
    "$(after_restore HomeNet yes/100 "$HOME_UUID")"
same "move failed, the copy is up on a channel the card cannot use: left up, demoted to no/0" \
    "rc=0 live=$UPLINK_CON tried=none drops=0 copy=no/0" \
    "$(after_restore "$UPLINK_CON" yes/100 "$HOME_UUID")"
same "move failed and nothing can log in: the copy is left at no/0, not at priority 100" \
    "rc=1 live=none tried=HomeNet drops=0 copy=no/0" \
    "$(after_restore "" yes/100 "$HOME_UUID" "NOAUTH=HomeNet $UPLINK_CON")"
same "no profile recorded from before the move: nothing is brought up, so not the copy" \
    "rc=1 live=none tried=none drops=0 copy=no/0" \
    "$(after_restore "" yes/100 "")"
same "mode A, wi-fi up on HomeNet: not re-activated, the old copy is deleted" \
    "rc=0 live=HomeNet tried=none drops=0 copy=absent" \
    "$(after_restore HomeNet no/0 "" PICK=HomeNet)"

# ---- R5 ----
section "R5: both scripts ignore HUP, INT and TERM right after the root check (read, not run)"
# trap_follows_root FILE: the first command after the root check's "fi" is the trap
trap_follows_root() {
    awk -v want="trap '' HUP INT TERM" '
        /^if \[ "\$\(id -u\)" -ne 0 \]; then$/ { root = 1; next }
        root && /^fi$/                         { after = 1; root = 0; next }
        after && NF && $1 !~ /^#/              { found = ($0 == want); exit }
        END                                    { exit !found }' "$1"
}
same "tailnet-ap-on.sh" yes "$(answer trap_follows_root "$ON")"
same "tailnet-ap-off.sh" yes "$(answer trap_follows_root "$OFF")"

# ---- R7 ----
section "R7: an empty answer from nmcli never lets the copy be deleted"
NM_ACTIVE=$'Wired connection 1:enp0s31f6\nHomeNet:wlp3s0\n'
same "copy_not_live: HomeNet is live, so the copy may go" yes "$(answer copy_not_live)"
NM_ACTIVE="$UPLINK_CON:wlp3s0"$'\n'
same "copy_not_live: the copy is live" no "$(answer copy_not_live)"
NM_ACTIVE=""
same "copy_not_live: nmcli printed nothing, which proves nothing" no "$(answer copy_not_live)"
NM_ACTIVE=$'Wired connection 1:enp0s31f6\n'
same "copy_not_live: nothing named on wlp3s0" no "$(answer copy_not_live)"
# the first outage: the copy was the live link, nmcli answered with nothing, and it was deleted
same "restore_uplink: the copy is live and nmcli names nothing: the copy is kept, demoted" \
    "rc=0 live=$UPLINK_CON tried=none drops=0 copy=no/0" \
    "$(after_restore "$UPLINK_CON" yes/100 "$HOME_UUID" BLANK=yes)"
# the --handback loop in tailnet-ap-off.sh is top-level code and cannot be run from here, so
# this reads both scripts: no delete guard may compare active_con with a bare "!=" any more
same "neither script tests \"\$(active_con)\" != on its own" \
    "" "$(grep -nF '"$(active_con)" != ' "$ON" "$OFF")"

# ---- R9 ----
section "R9: cable_ready wants carrier, an IPv4 address and a default route on the cable"
# after_cable CARRIER ADDR_AT ROUTE_AT: run cable_ready from tailnet-ap-on.sh. CARRIER is
# what /sys/class/net/enp0s31f6/carrier holds. ADDR_AT and ROUTE_AT say after how many
# one-second waits the cable has an IPv4 address and a default route: a number, or never.
# ip answers the way iproute2 prints: the brief form (-br) shows the address with no "inet"
# keyword, the one-line form (-o) shows "inet".
after_cable() {
    ( CARRIER=$1 ADDR_AT=$2 ROUTE_AT=$3 WAITS=0
      sleep() { WAITS=$((WAITS + 1)); }
      by_now() { [ "$1" != never ] && [ "$WAITS" -ge "$1" ]; }
      cat() {
          if [ "$*" = "/sys/class/net/$UP_IF/carrier" ]; then echo "$CARRIER"
          else command cat "$@"; fi
      }
      ip() {
          case "$*" in
              "-4 -br addr show $UP_IF"|"-4 -br addr show dev $UP_IF")
                  if by_now "$ADDR_AT"; then
                      printf '%-16s UP             192.168.1.20/24 \n' "$UP_IF"
                  fi ;;
              "-4 -o addr show $UP_IF"|"-4 -o addr show dev $UP_IF")
                  if by_now "$ADDR_AT"; then
                      printf '2: %s    inet 192.168.1.20/24 brd 192.168.1.255 scope global dynamic noprefixroute %s\\       valid_lft 86307sec preferred_lft 86307sec\n' "$UP_IF" "$UP_IF"
                  fi ;;
              "-4 route show default dev $UP_IF")
                  if by_now "$ROUTE_AT"; then
                      echo "default via 192.168.1.1 proto dhcp src 192.168.1.20 metric 100 "
                  fi ;;
              *) refused ip "$@" ;;
          esac
      }
      from_on cable_ready
      if cable_ready; then echo "ready after $WAITS waits"; else echo "not ready after $WAITS waits"; fi )
}
same "address and default route: ready at once" "ready after 0 waits" "$(after_cable 1 0 0)"
same "DHCP is slow, the route comes last: ready once both are there" \
    "ready after 4 waits" "$(after_cable 1 1 4)"
# passes before the fix too, because then nothing was ever ready; it is here to fail on a fix
# that only corrects the "inet" test, which the audit warns would open a new lockout
same "an address but no default route (isolated switch): not ready" \
    "not ready after 10 waits" "$(after_cable 1 0 never)"

# ---- the stubs ----
section "mode A runs the stack a Raspberry Pi would, not NetworkManager's hotspot"
if grep -q 'mode=ap' "$ON"; then
    bad "mode A builds no NetworkManager hotspot profile"
else
    ok "mode A builds no NetworkManager hotspot profile"
fi
same "both modes start the AP through the one shared function" 2 "$(grep -c 'start_ap_on "\$CH"' "$ON")"
check "mode A releases the radio before bringing the AP up" \
      grep -q 'nmcli dev disconnect "\$WIFI_IF"' "$ON"
check "the off script gives the wi-fi back once the AP is down" \
      grep -q 'giving the wi-fi back' "$OFF"

# ---- the active uplink ----
section "the firewall names the active uplink: the wi-fi in wifi mode, not the cable"
# ap_rules MODE: run start_ap_on in MODE, in a subshell, with iptables as the firewall and
# every command that would change the machine stubbed. -C finds no rule, so every rule is
# inserted; the inserts are recorded, not made. Prints the ones that name the uplink, so
# not the tailscale0 or INPUT rules.
ap_rules() {
    ( MADE="" PSK=$PSK_T
      sleep() { :; }; ip() { :; }; iw() { :; }; systemctl() { :; }
      fw_backend() { echo iptables; }
      iptables() { case " $* " in *" -C "*) return 1 ;; esac; MADE="$MADE$*"$'\n'; }
      start_ap_on 6 "$1" >/dev/null 2>&1
      printf '%s' "$MADE" | grep -v -e tailscale0 -e ' INPUT ' )
}
same "wifi mode: client traffic is masqueraded and forwarded out of wlp3s0, not enp0s31f6" \
    "-t nat -I POSTROUTING -s 10.42.7.1/24 -o wlp3s0 -j MASQUERADE
-I FORWARD -i ap0 -o wlp3s0 -j ACCEPT
-I FORWARD -i wlp3s0 -o ap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
    "$(ap_rules wifi)"

# ---- the advertised routes ----
section "adv_routes, routes_with, routes_without: the routes on adds to and off takes from"
# "tailscale debug prefs" as it prints the list: on one line, over several, null, empty,
# and cut off in the middle
PREFS_ONE=$'{\n\t"ControlURL": "https://controlplane.tailscale.com",\n\t"RouteAll": true,\n\t"AdvertiseRoutes": ["0.0.0.0/0", "10.42.7.0/24"],\n\t"WantRunning": true\n}'
PREFS_MULTI=$'{\n\t"RouteAll": true,\n\t"AdvertiseRoutes": [\n\t\t"0.0.0.0/0",\n\t\t"::/0",\n\t\t"10.42.7.0/24"\n\t],\n\t"WantRunning": true\n}'
PREFS_NULL=$'{\n\t"RouteAll": true,\n\t"AdvertiseRoutes": null,\n\t"WantRunning": true\n}'
PREFS_EMPTY=$'{\n\t"RouteAll": true,\n\t"AdvertiseRoutes": [],\n\t"WantRunning": true\n}'
PREFS_CUT=$'{\n\t"RouteAll": true,\n\t"AdvertiseRoutes": [\n\t\t"0.0.0.0/0",\n\t\t"10.42.7.0/24",'
PREFS_AP=$'{\n\t"RouteAll": true,\n\t"AdvertiseRoutes": [\n\t\t"10.42.7.0/24"\n\t],\n\t"WantRunning": true\n}'
# routes_read PREFS [nopython]: run adv_routes in a subshell with "tailscale debug prefs"
# printing PREFS, or failing with no output when PREFS is FAIL. nopython hides python3 from
# command -v, so the awk reader runs whatever the host has. Prints "rc=STATUS [ROUTES]".
routes_read() {
    ( FX_PREFS=$1
      tailscale() {
          [ "$*" = "debug prefs" ] || { refused tailscale "$@"; return; }
          [ "$FX_PREFS" != FAIL ] || return 1
          printf '%s\n' "$FX_PREFS"
      }
      if [ "${2:-}" = nopython ]; then
          command() {
              if [ "${1:-}" = -v ] && [ "${2:-}" = python3 ]; then return 1; fi
              builtin command "$@"
          }
      fi
      r=$(adv_routes); printf 'rc=%s [%s]' "$?" "$r" )
}
for how in default nopython; do
    if [ "$how" = default ]; then by=adv_routes; else by="adv_routes without python3"; fi
    same "$by: a list on one line" "rc=0 [0.0.0.0/0,10.42.7.0/24]" "$(routes_read "$PREFS_ONE" "$how")"
    same "$by: a list over several lines" "rc=0 [0.0.0.0/0,::/0,10.42.7.0/24]" "$(routes_read "$PREFS_MULTI" "$how")"
    same "$by: null, an empty list" "rc=0 []" "$(routes_read "$PREFS_NULL" "$how")"
    same "$by: [], an empty list" "rc=0 []" "$(routes_read "$PREFS_EMPTY" "$how")"
    same "$by: tailscale fails: a failure, not an empty list" "rc=1 []" "$(routes_read FAIL "$how")"
    same "$by: cut off mid-list: a failure, not an empty list" "rc=1 []" "$(routes_read "$PREFS_CUT" "$how")"
done
same "routes_with: an empty list gets the AP subnet alone" \
    "10.42.7.0/24" "$(routes_with "" 10.42.7.0/24)"
same "routes_with: added at the end, the others kept in order" \
    "0.0.0.0/0,::/0,10.42.7.0/24" "$(routes_with "0.0.0.0/0,::/0" 10.42.7.0/24)"
same "routes_with: already in the list, not added twice" \
    "0.0.0.0/0,10.42.7.0/24,::/0" "$(routes_with "0.0.0.0/0,10.42.7.0/24,::/0" 10.42.7.0/24)"
same "routes_with: 110.42.7.0/24 is another route, not the AP subnet" \
    "110.42.7.0/24,10.42.7.0/24" "$(routes_with "110.42.7.0/24" 10.42.7.0/24)"
same "routes_without: the AP subnet out of the middle, the rest in order" \
    "0.0.0.0/0,::/0" "$(routes_without "0.0.0.0/0,10.42.7.0/24,::/0" 10.42.7.0/24)"
same "routes_without: the AP subnet alone leaves an empty list" \
    "" "$(routes_without "10.42.7.0/24" 10.42.7.0/24)"
same "routes_without: an empty list stays empty" \
    "" "$(routes_without "" 10.42.7.0/24)"
same "routes_without: 110.42.7.0/24 is another route and stays" \
    "110.42.7.0/24,192.168.1.0/24" "$(routes_without "110.42.7.0/24,192.168.1.0/24" 10.42.7.0/24)"
same "on then off gives back the list as it was" \
    "0.0.0.0/0,::/0" "$(routes_without "$(routes_with "0.0.0.0/0,::/0" 10.42.7.0/24)" 10.42.7.0/24)"

# ---- update, the pure parts ----
section "update: the no-downgrade rule, the newest tag, the SHA256SUMS line"
same "update_verdict: 1.2.0 installed, 1.2.1 offered: install" install "$(update_verdict 1.2.0 1.2.1 aaa bbb)"
same "update_verdict: 1.9.0 installed, 1.10.0 offered: install (sort -V, not text order)" \
    install "$(update_verdict 1.9.0 1.10.0 aaa bbb)"
same "update_verdict: 1.2.0 installed, 1.1.4 offered: older, never installed" \
    older "$(update_verdict 1.2.0 1.1.4 aaa bbb)"
same "update_verdict: 1.10.0 installed, 1.9.9 offered: older (text order would say newer)" \
    older "$(update_verdict 1.10.0 1.9.9 aaa bbb)"
same "update_verdict: the same file: same" same "$(update_verdict 1.2.0 1.2.0 aaa aaa)"
same "update_verdict: the same version, another file: install, as before" \
    install "$(update_verdict 1.2.0 1.2.0 aaa bbb)"
same "update_verdict: no VERSION in the download: noversion" noversion "$(update_verdict 1.2.0 "" aaa bbb)"
# tag_of NAMES: what newest_tag makes of NAMES, one per line, as "rc=STATUS [TAG]"
tag_of() { local r; r=$(printf '%s\n' "$1" | newest_tag); printf 'rc=%s [%s]' "$?" "$r"; }
same "newest_tag: the highest by sort -V" "rc=0 [v1.10.0]" \
    "$(tag_of $'v1.1.0\nv1.1.4\nv1.9.2\nv1.10.0\nv1.2.0')"
same "newest_tag: only vMAJOR.MINOR.PATCH counts" "rc=0 [v1.2.0]" \
    "$(tag_of $'v2.0.0-rc1\nlatest\n1.3.0\nv1.3\nv1.2.0\nv1.1.4')"
same "newest_tag: no tags at all: fails" "rc=1 []" "$(tag_of "")"
same "newest_tag: no tag of that form: fails" "rc=1 []" "$(tag_of $'latest\nnightly')"
H1=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
H2=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
# sum_of SUMS: what sum_for tailnet-ap makes of the SHA256SUMS text SUMS, as "rc=STATUS [HASH]"
sum_of() { local r; r=$(printf '%s\n' "$1" | sum_for tailnet-ap); printf 'rc=%s [%s]' "$?" "$r"; }
same "sum_for: the line for tailnet-ap, not the one before it" "rc=0 [$H1]" \
    "$(sum_of "$H2  README.md"$'\n'"$H1  tailnet-ap")"
same "sum_for: sha256sum's binary-mode '*'" "rc=0 [$H1]" \
    "$(sum_of "$H2 *README.md"$'\n'"$H1 *tailnet-ap")"
same "sum_for: an upper-case hash, given in lower case" "rc=0 [$H1]" "$(sum_of "${H1^^}  tailnet-ap")"
same "sum_for: no line for tailnet-ap: fails" "rc=1 []" "$(sum_of "$H2  README.md")"
same "sum_for: tailnet-ap.bak and lib/tailnet-ap are other files: fails" "rc=1 []" \
    "$(sum_of "$H1  tailnet-ap.bak"$'\n'"$H1  lib/tailnet-ap")"

# ---- update, the whole command against a pretend GitHub ----
section "update: only a release tag, checked against its SHA256SUMS (GitHub is a stub)"
TAGS_FX=$'v1.1.4\nv1.10.0\nv9.9.9\nlatest\nv10.0.0-rc1'
# updated TAGS SUMS VER [ARG]: run do_update ARG in a subshell against a pretend GitHub, and
# print its exit status, then what it said. TAGS is the tag names, one per line. The tag
# v9.9.9 holds tailnet-ap, this program with VERSION=VER, and a SHA256SUMS unless SUMS is
# absent: good holds the file's real sum, bad a wrong one. fetch answers only the URLs
# update should ask for, pinned to v9.9.9, and refuses any other; json_names passes the
# names through, so neither the network nor python3 is used. mktemp makes its files in the
# scratch directory. cp and install stay refused, so an install would fail the run.
updated() {
    local st out
    out=$( (
        FX=$(mktemp -d "$SCRATCH/update.XXXXXX") FX_TAGS=$1 FX_SUMS=$2
        sed "s/^VERSION=.*/VERSION=$3/" "$LIB" > "$FX/tailnet-ap"
        case "$FX_SUMS" in
            good) printf '%s  tailnet-ap\n' "$(sha256sum "$FX/tailnet-ap" | cut -d' ' -f1)" > "$FX/SHA256SUMS" ;;
            bad)  printf '%064d  tailnet-ap\n' 0 > "$FX/SHA256SUMS" ;;
        esac
        shift 3
        SELF=$LIB
        command() {
            if [ "${1:-}" = -v ]; then
                case "${2:-}" in curl|python3) echo "/usr/bin/$2"; return 0 ;; esac
                return 1
            fi
            builtin command "$@"
        }
        mktemp() { command mktemp "$FX/tmp.XXXXXX"; }
        json_names() { cat; }
        fetch() {
            case "$1" in
                "$REPO_API/tags?"*) printf '%s\n' "$FX_TAGS" ;;
                "$REPO_API/contents?ref=v9.9.9")
                    printf 'README.md\ntailnet-ap\n'
                    [ "$FX_SUMS" = absent ] || echo SHA256SUMS ;;
                "$REPO_API/contents/tailnet-ap?ref=v9.9.9") cat "$FX/tailnet-ap" ;;
                "$REPO_API/contents/SHA256SUMS?ref=v9.9.9") cat "$FX/SHA256SUMS" ;;
                *) refused fetch "$@" ;;
            esac
        }
        do_update "$@"
    ) 2>&1 ); st=$?
    printf '%s\n%s\n' "$st" "$out"
}
# upd_says TEXT ARGS...: yes when "updated ARGS" says something holding TEXT, else no
upd_says() { local t=$1; shift; if updated "$@" | sed 1d | grep -qF -- "$t"; then echo yes; else echo no; fi; }
same "no tags at all: update stops with status 1" 1 "$(updated "" absent 9.9.9 --check | sed -n 1p)"
same "  and says there is no release tag" yes "$(upd_says "has no release tag" "" absent 9.9.9 --check)"
same "a newer release with a matching SHA256SUMS: --check exits 0" 0 \
    "$(updated "$TAGS_FX" good 9.9.9 --check | sed -n 1p)"
same "  it takes the highest vMAJOR.MINOR.PATCH tag" yes \
    "$(upd_says "release   : v9.9.9" "$TAGS_FX" good 9.9.9 --check)"
same "  the download matches SHA256SUMS" yes \
    "$(upd_says "checksum  : matches SHA256SUMS at v9.9.9" "$TAGS_FX" good 9.9.9 --check)"
same "  and the update is offered" yes "$(upd_says "an update is available" "$TAGS_FX" good 9.9.9 --check)"
same "a tag with no SHA256SUMS: one line says so" yes \
    "$(upd_says "checksum  : v9.9.9 has no SHA256SUMS, so the download is not checked against one" "$TAGS_FX" absent 9.9.9 --check)"
same "  and the update is still offered" yes "$(upd_says "an update is available" "$TAGS_FX" absent 9.9.9 --check)"
same "a wrong SHA256SUMS: --check stops with status 1" 1 "$(updated "$TAGS_FX" bad 9.9.9 --check | sed -n 1p)"
same "  and says the download does not match" yes \
    "$(upd_says "does NOT match SHA256SUMS at v9.9.9" "$TAGS_FX" bad 9.9.9 --check)"
same "a wrong SHA256SUMS: update stops with status 1, before cp or install" 1 \
    "$(updated "$TAGS_FX" bad 9.9.9 | sed -n 1p)"
same "  and says it refuses to install" yes "$(upd_says "refusing to install" "$TAGS_FX" bad 9.9.9)"
same "a release older than the installed one: update stops with status 1" 1 \
    "$(updated "$TAGS_FX" good 1.1.4 | sed -n 1p)"
same "  and names the downgrade" yes \
    "$(upd_says "is older than the installed one ($VERSION)" "$TAGS_FX" good 1.1.4)"
same "  --check names it too" yes \
    "$(upd_says "installed is newer than the remote ($VERSION > 1.1.4)" "$TAGS_FX" good 1.1.4 --check)"
same "the release is the installed file: --check says up to date" yes \
    "$(upd_says "up to date" "$TAGS_FX" good "$VERSION" --check)"
same "the program never names the main branch as a ref" "" "$(grep -n 'ref=main\|commits/main' "$LIB")"

# ---- doctor, the pure parts ----
section "doctor: the AP radio, the route approval, port 53"
IW_PHY_AP=$'Wiphy phy0\n\tmax # scan SSIDs: 4\n\tSupported interface modes:\n\t\t * IBSS\n\t\t * managed\n\t\t * AP\n\t\t * AP/VLAN\n\t\t * monitor\n\tBand 1:\n\t\tCapabilities: 0x1062'
IW_PHY_NOAP=$'Wiphy phy1\n\tSupported interface modes:\n\t\t * managed\n\t\t * AP/VLAN\n\t\t * monitor\n\tsoftware interface modes (can always be added):\n\t\t * AP/VLAN\n\t\t * monitor\n\tvalid interface combinations:\n\t\t * #{ managed } <= 1, #{ AP, P2P-client } <= 1,\n\t\t   total <= 3, #channels <= 1'
iw_ap() { if printf '%s\n' "$1" | iw_has_ap; then echo yes; else echo no; fi; }
same "iw_has_ap: AP among the supported interface modes" yes "$(iw_ap "$IW_PHY_AP")"
same "iw_has_ap: AP/VLAN only, and AP only in a combination: no" no "$(iw_ap "$IW_PHY_NOAP")"
same "iw_has_ap: iw printed nothing" no "$(iw_ap "")"
# "tailscale debug netmap", cut down to what route_approval reads. PrimaryRoutes holds the
# AP subnet in both, so only the packet filter tells them apart.
NETMAP_OK='{
    "SelfNode": {"Name": "pi.example.ts.net.", "PrimaryRoutes": ["10.42.7.0/24"]},
    "PacketFilter": [
        {"IPProto": [6, 17, 1, 58],
         "Srcs": ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "10.42.7.0/24"],
         "SrcCaps": null,
         "Dsts": [{"Net": "100.116.252.86/32", "Ports": {"First": 0, "Last": 65535}}],
         "Caps": []}
    ]
}'
NETMAP_NO='{
    "SelfNode": {"Name": "pi.example.ts.net.", "PrimaryRoutes": ["10.42.7.0/24"]},
    "PacketFilter": [
        {"IPProto": [6, 17, 1, 58],
         "Srcs": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"],
         "SrcCaps": null,
         "Dsts": [{"Net": "100.116.252.86/32", "Ports": {"First": 0, "Last": 65535}}],
         "Caps": []}
    ]
}'
NETMAP_ALL='{"PacketFilter": [{"IPProto": [6, 17], "Srcs": ["0.0.0.0/0", "::/0"], "Dsts": []}]}'
# route_approval needs python3, and without it says unknown for everything, which is what
# these expect then. The count of checks is the same either way.
if command -v python3 >/dev/null 2>&1; then HAVE_PY=yes; else HAVE_PY=no; fi
py_expect() { if [ "$HAVE_PY" = yes ]; then echo "$1"; else echo unknown; fi; }
approval_of() { printf '%s\n' "$1" | route_approval 10.42.7.0/24; }
same "route_approval: a packet-filter rule from the AP subnet: approved" \
    "$(py_expect yes)" "$(approval_of "$NETMAP_OK")"
same "route_approval: in PrimaryRoutes and in no rule: not approved" \
    "$(py_expect no)" "$(approval_of "$NETMAP_NO")"
same "route_approval: a rule from every source: cannot tell" unknown "$(approval_of "$NETMAP_ALL")"
same "route_approval: not JSON: cannot tell, never a guess" unknown "$(approval_of "permission denied")"
same "route_approval: no PacketFilter at all: cannot tell" unknown "$(approval_of '{"Peers": []}')"
SS_OURS='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
UNCONN 0      0      127.0.0.53%lo:53     0.0.0.0:*         users:(("systemd-resolve",pid=500,fd=13))
UNCONN 0      0      0.0.0.0:5353         0.0.0.0:*         users:(("avahi-daemon",pid=600,fd=12))
UNCONN 0      0      10.42.7.1:53         0.0.0.0:*         users:(("dnsmasq",pid=900,fd=6))'
SS_NAMED='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
UNCONN 0      0      127.0.0.53%lo:53     0.0.0.0:*         users:(("systemd-resolve",pid=500,fd=13))
UNCONN 0      0      0.0.0.0:5353         0.0.0.0:*         users:(("avahi-daemon",pid=600,fd=12))
UNCONN 0      0      0.0.0.0:53           0.0.0.0:*         users:(("named",pid=700,fd=5))'
# held SS [PID]: what port53_holders says for 10.42.7.1 on ap0, as "rc=STATUS [HOLDERS]"
held() { local r; r=$(printf '%s\n' "$1" | port53_holders 10.42.7.1 ap0 "${2:-}"); printf 'rc=%s [%s]' "$?" "$r"; }
same "port53_holders: only the AP's own dnsmasq, by its pid: nothing else holds it" \
    "rc=1 []" "$(held "$SS_OURS" 900)"
same "port53_holders: without its pid the same socket is named" \
    "rc=0 [10.42.7.1:53 (dnsmasq)]" "$(held "$SS_OURS")"
same "port53_holders: a server on every address is named; loopback and 5353 are not" \
    "rc=0 [0.0.0.0:53 (named)]" "$(held "$SS_NAMED")"
same "port53_holders: without root ss names no process" \
    "rc=0 [*:53 (unknown process)]" "$(held 'LISTEN 0      32     *:53      *:*')"

# ---- doctor, the whole command on a pretend machine ----
section "doctor: its exit status is the verdict, and advertised is not approved"
# doctored [NAME=VALUE...]: run do_doctor in a subshell on a pretend machine, and print its
# exit status, then what it printed. The machine, unless a NAME=VALUE says otherwise:
#   HAVE      what command -v finds: hostapd dnsmasq iw nmcli tailscale ss. Not python3,
#             so adv_routes reads with awk whatever the host has.
#   RADIO     what ap_radio answers: yes
#   STATE     tailscale's BackendState: Running
#   PREFS     "tailscale debug prefs": $PREFS_NULL, no route advertised
#   APPROVAL  what route_approval answers: no
#   SS        "ss -lunp": nothing on port 53
# Every command doctor runs is a stub or reads only, and the AP's pid file is not there.
doctored() {
    local st out
    out=$( (
        HAVE="hostapd dnsmasq iw nmcli tailscale ss" RADIO=yes STATE=Running
        PREFS=$PREFS_NULL APPROVAL=no SS="" DNSMASQ_PID=$SCRATCH/none.pid
        for kv in "$@"; do printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
        command() {
            if [ "${1:-}" = -v ]; then
                case " $HAVE " in *" ${2:-} "*) echo "/usr/bin/$2"; return 0 ;; esac
                return 1
            fi
            builtin command "$@"
        }
        ap_radio() { echo "$RADIO"; }
        route_approval() { cat >/dev/null; echo "$APPROVAL"; }
        tailscale() {
            case "$*" in
                "debug prefs")   printf '%s\n' "$PREFS" ;;
                "debug netmap")  echo '{}' ;;
                "status --json") printf '{\n\t"Version": "1.90.0",\n\t"BackendState": "%s"\n}\n' "$STATE" ;;
                *) refused tailscale "$@" ;;
            esac
        }
        ss() {
            case "$*" in
                -lunp) printf '%s\n' "$SS" ;;
                -ltnp) ;;
                *) refused ss "$@" ;;
            esac
        }
        do_doctor
    ) 2>&1 ); st=$?
    printf '%s\n%s\n' "$st" "$out"
}
# doctor_says TEXT NAME=VALUE...: yes when doctor prints something holding TEXT there, else no
doctor_says() { local t=$1; shift; if doctored "$@" | sed 1d | grep -qF -- "$t"; then echo yes; else echo no; fi; }
APPROVE="approve the subnet route in the Tailscale admin console"
same "a machine with everything the AP needs: exit 0" 0 "$(doctored | sed -n 1p)"
for t in hostapd dnsmasq iw; do
    have=" hostapd dnsmasq iw nmcli tailscale ss "
    same "$t missing: exit 1" 1 "$(doctored "HAVE=${have/ $t / }" | sed -n 1p)"
done
same "  and the verdict names what is missing" yes \
    "$(doctor_says "NOT READY: iw is missing" "HAVE=hostapd dnsmasq nmcli tailscale ss")"
same "tailscale missing is reported, not a failure: exit 0" 0 \
    "$(doctored "HAVE=hostapd dnsmasq iw nmcli ss" | sed -n 1p)"
same "no radio that can be an access point: exit 1" 1 "$(doctored RADIO=no | sed -n 1p)"
same "HOSTIP is the network address, so no usable subnet: exit 1" 1 "$(doctored HOSTIP=10.42.7.0 | sed -n 1p)"
same "route advertised and not approved: says to approve it" yes \
    "$(doctor_says "$APPROVE" "PREFS=$PREFS_AP" APPROVAL=no)"
same "route advertised and approved: does not" no "$(doctor_says "$APPROVE" "PREFS=$PREFS_AP" APPROVAL=yes)"
same "route not advertised: does not" no "$(doctor_says "$APPROVE" "PREFS=$PREFS_NULL" APPROVAL=no)"
same "approval cannot be read: does not" no "$(doctor_says "$APPROVE" "PREFS=$PREFS_AP" APPROVAL=unknown)"
same "  and says it cannot tell" yes \
    "$(doctor_says "advertised; approval unknown" "PREFS=$PREFS_AP" APPROVAL=unknown)"
same "tailscale logged out: says so" yes "$(doctor_says "NeedsLogin: NOT logged in and running" STATE=NeedsLogin)"
same "  a warning, not a failure: exit 0" 0 "$(doctored STATE=NeedsLogin | sed -n 1p)"
same "something else on port 53: a warning naming it" yes "$(doctor_says "0.0.0.0:53 (named)" "SS=$SS_NAMED")"
same "nothing else on port 53: free" yes "$(doctor_says "free for 10.42.7.1")"

# ---- install: the settings file ----
section "install writes the settings file with the interfaces detection found"
# settings_written: run load_config, then install_settings (install's settings step), in a
# subshell with no settings file yet and no TAILNET_AP_* variable. Between the two, UP_IF,
# WIFI_IF and DESKTOP_USER are set the way detect_ifaces and detect_desktop_user set them
# on a Raspberry Pi, which this host need not be. $CONFFILE is in the scratch directory.
# Prints the UP_IF, WIFI_IF and DESKTOP_USER lines of the file written, on one line.
settings_written() {
    ( CONFFILE=$(mktemp -d "$SCRATCH/conf.XXXXXX")/tailnet-ap.conf
      unset TAILNET_AP_SSID TAILNET_AP_COUNTRY TAILNET_AP_HOSTRECORD TAILNET_AP_UPLINK \
            TAILNET_AP_WIFI TAILNET_AP_USER
      load_config
      UP_IF=eth0 WIFI_IF=wlan0 DESKTOP_USER=pi
      install_settings >/dev/null
      grep -E '^(UP_IF|WIFI_IF|DESKTOP_USER)=' "$CONFFILE" | paste -sd' ' - )
}
same "the file names the detected eth0 and wlan0, not enp0s31f6 and wlp3s0; DESKTOP_USER stays as read" \
    "UP_IF=eth0 WIFI_IF=wlan0 DESKTOP_USER=" "$(settings_written)"

# ---- off: the wi-fi goes back only when the AP took it ----
section "off gives the wi-fi back only when the AP took it, or when --handback asks"
# after_off WAS_UP [ARG]: run do_off ARG in a subshell after cable mode, whose record says
# WAS_UP (yes or no) for whether the wi-fi was connected when the AP took the radio.
# wlp3s0 is disconnected and there is no 2.4 GHz copy; the pretend NetworkManager brings
# HomeNet up on "dev connect". The firewall, systemd, iw and tailscale (no routes) are
# stubs, and AP_IF names no interface, so off finds no ap0 to delete. Prints what
# NetworkManager was asked to bring up, whether off said it was giving the wi-fi back,
# whether it warned that the wi-fi did not come back, and whether the record is gone.
after_off() {
    ( STATEDIR=$(mktemp -d "$SCRATCH/state.XXXXXX"); ON_RECORD=$STATEDIR/on-record
      OUT=$(mktemp "$SCRATCH/off.XXXXXX") AP_IF=tnaptest0
      pretend_nm "" absent
      fw_remove() { :; }; systemctl() { return 1; }; iw() { :; }
      tailscale() {
          [ "$*" = "debug prefs" ] || { refused tailscale "$@"; return; }
          printf '%s\n' "$PREFS_NULL"
      }
      write_on_record cable no "$1"; shift
      do_off "$@" > "$OUT" 2>&1
      said() { if grep -qF -- "$1" "$OUT"; then echo yes; else echo no; fi; }
      printf 'tried=%s gave-back=%s warned=%s record=%s' "${TRIED:-none}" \
          "$(said "giving the wi-fi back")" "$(said "warning: the wi-fi did not come back")" \
          "$(if [ -e "$ON_RECORD" ]; then echo kept; else echo gone; fi)" )
}
same "off after cable mode, the wi-fi never up (a Pi): no connect, no 'giving the wi-fi back'; --handback still does" \
    "off: tried=none gave-back=no warned=no record=gone | off --handback: tried=HomeNet gave-back=yes warned=no record=gone" \
    "off: $(after_off no) | off --handback: $(after_off no --handback)"
same "off after cable mode took a connected wi-fi (the ThinkPad): it is still given back" \
    "tried=HomeNet gave-back=yes warned=no record=gone" "$(after_off yes)"

section "safety"
if [ -s "$SCRATCH/refused" ]; then
    bad "nothing that changes the machine was called" "$(tr '\n' ';' < "$SCRATCH/refused")"
else
    ok "nothing that changes the machine was called"
fi

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
