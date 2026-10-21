#!/usr/bin/env bash
# test-rotate-lxc-ssh — run the address and exit-code logic of rotate-lxc-ssh.sh on recorded
# answers (PET-729). The lab produced these shapes on 2026-10-21: a container with no
# authorized_keys (102, 112, 221), an address on net1 (seerr 101) and a DHCP container (102).
#
#   ./scripts/test-rotate-lxc-ssh.sh
#
# Contacts nothing. It sources the shipped script with ROTATE_LXC_SSH_SOURCE_ONLY=1, so the
# functions under test are the real ones, and it replaces on_node with a local runner.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       want %s, got %s\n' "$1" "$2" "$3"; }
eq()   { [ "$3" = "$2" ] && ok "$1" || bad "$1" "[$2]" "[$3]"; }

export ROTATE_LXC_SSH_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$HERE/rotate-lxc-ssh.sh"
set +e
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "config_ip"
eq "net0 static" 192.168.50.112 "$(config_ip <<<$'arch: amd64\nnet0: name=eth0,bridge=vmbr0,gw=192.168.50.1,hwaddr=AA:BB,ip=192.168.50.112/24,type=veth')"
eq "net1 static (seerr)" 192.168.50.101 "$(config_ip <<<$'net0: name=eth0,bridge=vmbr0,hwaddr=AA:BB,type=veth\nnet1: name=eth1,bridge=vmbr0,ip=192.168.50.101/24,type=veth')"
eq "dhcp" "" "$(config_ip <<<'net0: name=eth0,bridge=vmbr0,ip=dhcp,type=veth')"
eq "no net line" "" "$(config_ip <<<'arch: amd64')"
eq "first static wins" 10.0.0.5 "$(config_ip <<<$'net0: name=eth0,ip=dhcp\nnet1: name=eth1,ip=10.0.0.5/24\nnet2: name=eth2,ip=10.0.0.6/24')"

echo "pick_ip"
eq "prefers the LAN" 192.168.50.7 "$(pick_ip <<<$'192.168.86.4\n192.168.50.7')"
eq "falls back to the first" 192.168.86.4 "$(pick_ip <<<$'192.168.86.4\n10.1.1.1')"
eq "ignores noise" "" "$(pick_ip <<<$'fe80::1\n\n')"
eq "empty" "" "$(pick_ip </dev/null)"

echo "has_key exit codes (pct stubbed to run the command locally)"
export AUTH="$T/authorized_keys"
MAT=AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExample1234567
FAKE_RC=0
on_node() { shift; eval "$*"; }
pct() { [ "$FAKE_RC" -eq 0 ] || return "$FAKE_RC"; shift 3; "$@"; }
rm -f "$AUTH"
has_key 102 n "$MAT"; eq "file absent -> absent (1)" 1 $?
printf 'ssh-ed25519 OTHER x\n' > "$AUTH"
has_key 1 n "$MAT"; eq "key not in file -> absent (1)" 1 $?
printf 'ssh-ed25519 %s c\n' "$MAT" >> "$AUTH"
has_key 1 n "$MAT"; eq "key in file -> present (0)" 0 $?
FAKE_RC=255; has_key 1 n "$MAT"; eq "pct exec / ssh failure stays a fault (255)" 255 $?
FAKE_RC=2;   has_key 1 n "$MAT"; eq "read error stays a fault (2)" 2 $?
FAKE_RC=0
chmod 000 "$AUTH"; has_key 1 n "$MAT"; rc=$?; chmod 600 "$AUTH"
[ "$(id -u)" -eq 0 ] && ok "unreadable file (skipped: running as root reads it)" || eq "unreadable file stays a fault (2)" 2 "$rc"

echo "live_ip (on_node stubbed with recorded output)"
on_node() { case "$2" in *hostname*) printf '%s\n' "$HOSTNAME_I" ;; *"ip -4"*) printf '%s\n' "$IPA" ;; esac; }
HOSTNAME_I="192.168.50.102 "; IPA=""
eq "hostname -I" 192.168.50.102 "$(live_ip 102 n)"
HOSTNAME_I=""; IPA='2: eth0    inet 192.168.50.103/24 brd 192.168.50.255 scope global eth0'
eq "ip addr fallback ignores brd" 192.168.50.103 "$(live_ip 102 n)"
HOSTNAME_I=""; IPA=""
eq "nothing comes back" "" "$(live_ip 102 n)"

echo
echo "$PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] && [ "$PASS" -ge 15 ] || exit 1
