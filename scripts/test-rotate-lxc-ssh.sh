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
PASS=0; FAIL=0; SKIPPED=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  SKIP %s\n' "$1"; }
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
eq "takes the LAN address" 192.168.50.7 "$(pick_ip <<<$'192.168.86.4\n192.168.50.7')"
eq "no non-LAN fallback" "" "$(pick_ip <<<$'192.168.86.4\n10.1.1.1')"
eq "ignores noise" "" "$(pick_ip <<<$'fe80::1\n\n')"
eq "empty" "" "$(pick_ip </dev/null)"

echo "has_key exit codes (pct stubbed to run the command locally)"
export AUTH="$T/authorized_keys"
MAT=AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExample1234567
FAKE_RC=0
on_node() { shift; eval "$*"; }
# A failed pct exec or ssh prints nothing and exits non-zero, 1 included.
pct() { [ "$FAKE_RC" -eq 0 ] || return "$FAKE_RC"; shift 3; "$@"; }
rm -f "$AUTH"
has_key 102 n "$MAT"; eq "file absent -> absent (1)" 1 $?
printf 'ssh-ed25519 OTHER x\n' > "$AUTH"
has_key 1 n "$MAT"; eq "key not in file -> absent (1)" 1 $?
printf 'ssh-ed25519 %s c\n' "$MAT" >> "$AUTH"
has_key 1 n "$MAT"; eq "key in file -> present (0)" 0 $?
FAKE_RC=1;   has_key 1 n "$MAT"; eq "failed pct exec exiting 1 is a fault, not absent (2)" 2 $?
FAKE_RC=255; has_key 1 n "$MAT"; eq "failed pct exec / ssh exiting 255 is a fault (2)" 2 $?
FAKE_RC=0
mkdir "$T/bin"; printf '#!/bin/sh\nexit 2\n' > "$T/bin/grep"; chmod +x "$T/bin/grep"
PATH="$T/bin:$PATH" has_key 1 n "$MAT"; eq "grep read error is a fault (2)" 2 $?
chmod 000 "$AUTH"; has_key 1 n "$MAT"; rc=$?; chmod 600 "$AUTH"
if [ "$(id -u)" -eq 0 ]; then skip "unreadable file: root reads it, so this case did not run (the fake-grep case above covers the fault path)"
else eq "unreadable file is a fault (2)" 2 "$rc"; fi

echo "live_ip (on_node stubbed with recorded output)"
on_node() { case "$2" in *hostname*) printf '%s\n' "$HOSTNAME_I" ;; *"ip -4"*) printf '%s\n' "$IPA" ;; esac; }
HOSTNAME_I="192.168.50.102 "; IPA=""
eq "hostname -I" 192.168.50.102 "$(live_ip 102 n)"
HOSTNAME_I="192.168.86.9 172.17.0.2"; IPA=""
eq "no LAN address -> nothing (a fault upstream)" "" "$(live_ip 102 n)"
HOSTNAME_I="192.168.86.9"; IPA='2: eth0    inet 192.168.50.104/24 brd 192.168.50.255 scope global eth0'
eq "mesh from hostname -I, LAN from ip addr" 192.168.50.104 "$(live_ip 102 n)"
HOSTNAME_I=""; IPA='2: eth0    inet 192.168.50.103/24 brd 192.168.50.255 scope global eth0'
eq "ip addr fallback ignores brd" 192.168.50.103 "$(live_ip 102 n)"
HOSTNAME_I=""; IPA=""
eq "nothing comes back" "" "$(live_ip 102 n)"

echo "ctip (a DHCP address is read again at each use)"
HOSTNAME_I="192.168.50.110"; IPA=""
eq "static passes through" 192.168.50.5 "$(ctip n 102 192.168.50.5)"
eq "dhcp, first read" 192.168.50.110 "$(ctip n 102 none)"
HOSTNAME_I="192.168.50.111"
eq "dhcp, lease changed" 192.168.50.111 "$(ctip n 102 none)"

echo
echo "$PASS passed, $FAIL failed, $SKIPPED skipped."
[ "$FAIL" -eq 0 ] && [ "$PASS" -ge 18 ] || exit 1
