#!/usr/bin/env bash
# rotate-lxc-ssh.sh — replace the key pair in kv/iac/lxc-ssh and swap it inside every LXC that
# trusts it, without replacing a container (PET-729).
#
# WHY: PET-725 takes kv/iac/lxc-ssh out of the claude_ops policy, but a policy change cannot
# take back a key claude-ops already read. That key stays root on every Terraform LXC until
# the key pair changes.
#
# NO LXC IS REPLACED. modules/proxmox-lxc/main.tf lists initialization[0].user_account in
# ignore_changes, so the new TF_VAR_ssh_public_key that Terraform reads from Vault after this
# run shows up as no diff. This script edits /root/.ssh/authorized_keys inside each running
# container with `pct exec` from the node, which needs the node login and not the key that is
# being rotated.
#
# ORDER, SO CI KEEPS A WORKING KEY AT EVERY MOMENT:
#   1. Read the old key pair from Vault. List every running container on pve02 and pve03 and
#      record which ones trust the old key.
#   2. Generate the new pair in a 0700 temp directory. Append the new public key to each
#      container that trusts the old one.
#   3. Log in to each container with the NEW key over SSH. Any failure stops the run here,
#      before Vault changes, and leaves both keys in place.
#   4. Write the new pair to Vault. The old public key goes in `previous_public_key` so a
#      re-run can finish the job.
#   5. Remove the old public key from each container.
#   6. Read back: the new key logs in, the old key's material is gone from every file, and the
#      old private key is refused with "Permission denied" on every container.
#   7. Delete `previous_public_key` from Vault and replace ~/.ssh/id_ed25519_ansible.
#
# RE-RUN: if Vault holds `previous_public_key`, a run resumes at step 5 with the key already in
# Vault. A container that was stopped is reported and makes the run exit 1; start it and re-run.
#
# WHAT IT CANNOT SEE: VMs and bare-metal hosts, and a container that trusts the key from a
# file other than /root/.ssh/authorized_keys. The summary line names what the run examined.
#
# NO SECRET REACHES AN ARGUMENT LIST OR STDOUT. Private keys live in the temp directory
# (umask 077) and go to Vault as `@file`. Public key material, which is not a secret, does
# appear in `pct exec` arguments.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#
# Usage:
#   ./scripts/rotate-lxc-ssh.sh --check    # step 1 only: read, change nothing
#   ./scripts/rotate-lxc-ssh.sh            # rotate
#   ./scripts/rotate-lxc-ssh.sh --no-local # rotate, but leave ~/.ssh/id_ed25519_ansible alone
set -euo pipefail
umask 077

CHECK=0
LOCAL=1
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --no-local) LOCAL=0 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
KV=kv/iac/lxc-ssh
AUTH=/root/.ssh/authorized_keys
LOCAL_KEY="$HOME/.ssh/id_ed25519_ansible"

# Root on both nodes, by address, with the key named (PET-561).
NODES=(root@192.168.50.11 root@192.168.50.10)
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
on_node() { local host="$1"; shift; ssh -o ConnectTimeout=8 -o BatchMode=yes -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$host" "$@"; }

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*" >&2; }

material() { awk '{print $2}' <<<"$1"; }
valid_material() { [[ "$1" =~ ^[A-Za-z0-9+/=]{40,}$ ]]; }

# has_key <vmid> <node> <material>: 0 present, 1 absent, 2 anything else (a fault).
# The container prints PRESENT or ABSENT itself, so a failed pct exec or ssh, which can also
# exit 1, prints nothing and cannot pass for "absent". A container with no $AUTH trusts no key
# from that file, so a missing file is ABSENT. grep exit 2 (a read error) is a fault.
HAS_KEY_SH='if [ ! -f "$1" ]; then echo ABSENT; exit 0; fi; grep -qF "$2" "$1"; r=$?; if [ $r -eq 0 ]; then echo PRESENT; elif [ $r -eq 1 ]; then echo ABSENT; else echo ERR; fi'
has_key() {
  local out
  out="$(on_node "$2" "pct exec $1 -- sh -c '$HAS_KEY_SH' _ $AUTH $3" 2>/dev/null)" || return 2
  case "$out" in
    PRESENT) return 0 ;;
    ABSENT) return 1 ;;
    *) return 2 ;;
  esac
}

# remove_key <vmid> <node> <material>: drops every line holding the material from $AUTH.
# grep exits 1 when nothing is left, which is fine for the filter but not for this file, so an
# empty result is refused and the file stays as it was. A grep read error (exit 2 or more) is
# refused the same way. The container prints OK only after the file is rewritten; anything
# else, including a failed pct exec, makes this return 1.
REMOVE_KEY_SH='f="$1"; grep -vF "$2" "$f" > "$f.rot"; r=$?; if [ $r -ge 2 ]; then rm -f "$f.rot"; echo GREP_ERROR; exit 0; fi; if [ ! -s "$f.rot" ]; then rm -f "$f.rot"; echo WOULD_EMPTY; exit 0; fi; cat "$f.rot" > "$f" && rm -f "$f.rot" && echo OK'
remove_key() {
  local out
  out="$(on_node "$2" "pct exec $1 -- sh -c '$REMOVE_KEY_SH' _ $AUTH $3" 2>/dev/null)" || return 1
  [ "$out" = OK ] || { printf '%s' "$out" > "${TMP:-/tmp}/remove_key_reason" 2>/dev/null || true; return 1; }
}

# config_ip: reads `pct config` on stdin, prints the first static IPv4 across every netN line
# (seerr 101 keeps its address on net1), or nothing when every netN is DHCP or has no ip=.
config_ip() {
  sed -n 's/^net[0-9][0-9]*:.*,ip=\([0-9][0-9.]*\)\/.*/\1/p' | head -1
}

# pick_ip: reads candidate IPv4 addresses on stdin, one per line. Prints the first one on the
# lab LAN (192.168.50.0/24) and nothing else: the Mac reaches no other segment, so a mesh or
# Docker address would make the probe fail for a reason that has nothing to do with the key.
pick_ip() {
  grep -m1 -E '^192\.168\.50\.[0-9]+$' || true
}

# live_ip <vmid> <node>: asks the running container for its address, for DHCP containers
# (flaresolverr 102). Prints nothing when no LAN address comes back.
live_ip() {
  local out
  out="$(on_node "$2" "pct exec $1 -- hostname -I" 2>/dev/null | tr ' ' '\n' || true)"
  if ! grep -qE '^192\.168\.50\.[0-9]+$' <<<"$out"; then
    out="$(on_node "$2" "pct exec $1 -- ip -4 -o addr show scope global" 2>/dev/null \
      | grep -oE 'inet [0-9.]+' | awk '{print $2}' || true)"
  fi
  pick_ip <<<"$out"
}

# ctip <node> <vmid> <ip>: the address to use now. A static address passes through; a DHCP
# container (ip none) is asked again each time, because the lease can change during a run.
ctip() {
  if [ "$3" != none ]; then echo "$3"; else live_ip "$2" "$1"; fi
}

# login <ip> <keyfile>: prints ok, denied, refused or unreachable. "refused" is a closed port 22:
# no sshd listens, so the old key cannot log in there (cloud-flare-main 112). A timeout stays
# unreachable, because a flaky network proves nothing about the key.
login() {
  local err rc=0
  [ -n "$1" ] || { echo unreachable; return; }
  err="$(ssh -n -o ConnectTimeout=6 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    -i "$2" "root@$1" true 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then echo ok
  elif grep -q 'Permission denied' <<<"$err"; then echo denied
  elif grep -q 'Connection refused' <<<"$err"; then echo refused
  else echo unreachable
  fi
}

# Tests source this file for the functions above; nothing below runs then.
[ "${ROTATE_LXC_SSH_SOURCE_ONLY:-}" = 1 ] && return 0

for t in vault jq ssh ssh-keygen awk; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root on the nodes accepts."
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run from inside the repo or export it."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "Authenticating to Vault"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. This script does not prompt."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Reading $KV"
CUR_JSON="$(vault kv get -format=json "$KV")" || die "Could not read $KV."
CUR_PUB="$(jq -r '.data.data.public_key // empty' <<<"$CUR_JSON")"
PREV_PUB="$(jq -r '.data.data.previous_public_key // empty' <<<"$CUR_JSON")"
[ -n "$CUR_PUB" ] || die "$KV has no public_key."
jq '.data.data' <<<"$CUR_JSON" > "$TMP/cur_data.json"
jq -r '.data.data.private_key // empty' <<<"$CUR_JSON" > "$TMP/vault_private"
[ -s "$TMP/vault_private" ] || die "$KV has no private_key."
unset CUR_JSON

if [ -n "$PREV_PUB" ]; then
  echo "  previous_public_key is set: a rotation did not finish. Resuming at the removal step."
  RESUME=1
  NEW_MAT="$(material "$CUR_PUB")"
  OLD_MAT="$(material "$PREV_PUB")"
  mv "$TMP/vault_private" "$TMP/new_key"
  printf '%s\n' "$CUR_PUB" > "$TMP/new_key.pub"
else
  RESUME=0
  OLD_MAT="$(material "$CUR_PUB")"
  NEW_MAT=""
  mv "$TMP/vault_private" "$TMP/old_key"
  printf '%s\n' "$CUR_PUB" > "$TMP/old_key.pub"
fi
valid_material "$OLD_MAT" || die "The old public key material does not look like base64."
[ -z "$NEW_MAT" ] || valid_material "$NEW_MAT" || die "The new public key material does not look like base64."

step "Listing containers on the nodes"
# Each row: node vmid ip status. A stopped container cannot be read with pct exec.
ROWS="$TMP/rows"; : > "$ROWS"
for node in "${NODES[@]}"; do
  LIST="$(on_node "$node" "pct list")" || die "pct list failed on $node."
  while read -u 3 -r vmid status _; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    cfg="$(on_node "$node" "pct config $vmid" 2>/dev/null || true)"
    ip="$(config_ip <<<"$cfg")"
    printf '%s %s %s %s\n' "$node" "$vmid" "${ip:-none}" "$status" >> "$ROWS"
  done 3<<<"$(tail -n +2 <<<"$LIST")"
done
TOTAL="$(grep -c . "$ROWS" || true)"
[ "$TOTAL" -ge 5 ] || die "Listed only $TOTAL containers across ${#NODES[@]} nodes. The lab has more; refusing to rotate on a partial list."
echo "  $TOTAL containers listed."

step "Finding which containers trust the key"
TARGETS="$TMP/targets"; : > "$TARGETS"
STOPPED=(); FAULTS=(); SKIPPED=()
while read -u 3 -r node vmid ip status; do
  if [ "$status" != running ]; then STOPPED+=("$vmid($status)"); continue; fi
  hasold=0; hasnew=0; rc=0
  has_key "$vmid" "$node" "$OLD_MAT" || rc=$?
  case "$rc" in 0) hasold=1 ;; 1) ;; *) FAULTS+=("$vmid:read"); continue ;; esac
  if [ -n "$NEW_MAT" ]; then
    rc=0; has_key "$vmid" "$node" "$NEW_MAT" || rc=$?
    case "$rc" in 0) hasnew=1 ;; 1) ;; *) FAULTS+=("$vmid:read"); continue ;; esac
  fi
  if [ "$hasold" -eq 0 ] && [ "$hasnew" -eq 0 ]; then
    SKIPPED+=("$vmid")
    # Not in $AUTH does not mean the old key is refused: a second file or another sshd
    # setting can still trust it. Probe it with the old private key where we hold one.
    if [ -f "$TMP/old_key" ]; then
      a="$(ctip "$node" "$vmid" "$ip")"
      [ -n "$a" ] || { FAULTS+=("$vmid:no-address"); continue; }
      r="$(login "$a" "$TMP/old_key")"
      case "$r" in
        denied|refused) ;;
        ok) FAULTS+=("$vmid:old-key-trusted-outside-$AUTH") ;;
        *) FAULTS+=("$vmid:old-key-probe-$r") ;;
      esac
    fi
    continue
  fi
  a="$(ctip "$node" "$vmid" "$ip")"
  if [ -z "$a" ]; then FAULTS+=("$vmid:no-address"); continue; fi
  printf '%s %s %s %s %s\n' "$node" "$vmid" "$ip" "$hasold" "$hasnew" >> "$TARGETS"
  echo "  CT $vmid ($a): old=$hasold new=$hasnew"
done 3< "$ROWS"
NTARGET="$(grep -c . "$TARGETS" || true)"
PROBED="refused the old private key"; [ -f "$TMP/old_key" ] || PROBED="not probed with the old private key (resume)"
echo "  $NTARGET trust the key; ${#SKIPPED[@]} do not list it in $AUTH and $PROBED (${SKIPPED[*]:-none}); ${#STOPPED[@]} not running (${STOPPED[*]:-none}); ${#FAULTS[@]} unreadable (${FAULTS[*]:-none})."
[ "${#FAULTS[@]}" -eq 0 ] || die "Could not read, address or probe: ${FAULTS[*]}. A name ending old-key-trusted-outside means the old private key still logs in there by a path this script does not edit. Fix these first; nothing was changed."
# Before any change: a stopped container that trusts only the old key would be left behind
# after Vault and the other containers move on.
[ "${#STOPPED[@]}" -eq 0 ] || die "Containers not running: ${STOPPED[*]}. Start them, or destroy them, and re-run; nothing was changed."
[ "$NTARGET" -gt 0 ] || die "No running container trusts the key. Refusing to continue; nothing was changed."

if [ "$CHECK" -eq 1 ]; then
  echo
  echo "--check: examined $TOTAL containers on ${#NODES[@]} nodes; $NTARGET trust the key; changed nothing."
  exit 0
fi

if [ "$RESUME" -eq 0 ]; then
  step "Generating the new key pair"
  ssh-keygen -q -t ed25519 -N '' -C "lxc-ssh@petedio-$(date +%Y%m%d)" -f "$TMP/new_key"
  NEW_PUB="$(cat "$TMP/new_key.pub")"
  NEW_MAT="$(material "$NEW_PUB")"
  valid_material "$NEW_MAT" || die "The generated public key material does not look like base64."

  # Add a newline first when the file lacks one, or the new key glues onto the last line.
  APPEND_SH='f=/root/.ssh/authorized_keys; if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi; cat >> "$f"'

  step "Appending the new public key"
  while read -u 3 -r node vmid ip hasold hasnew; do
    if [ "$hasnew" -eq 1 ]; then echo "  CT $vmid already has it"; continue; fi
    printf '%s\n' "$NEW_PUB" | on_node "$node" "pct exec $vmid -- sh -c '$APPEND_SH'" \
      || die "Could not append to CT $vmid. Vault is unchanged and the old key still works everywhere; CTs appended before this one keep the new key, which a re-run does not reuse."
    echo "  CT $vmid appended"
  done 3< "$TARGETS"

  step "Logging in to every container with the NEW key"
  while read -u 3 -r node vmid ip hasold hasnew; do
    a="$(ctip "$node" "$vmid" "$ip")"; r="$(login "$a" "$TMP/new_key")"
    [ "$r" = ok ] || die "New key: CT $vmid (${a:-no address}) answered '$r'. Stopped before Vault changed; the old key still works. A re-run generates another pair and leaves this run's appended key trusted with no private key, so remove lines ending lxc-ssh@petedio-<date> from $AUTH by hand."
    echo "  CT $vmid (${a:-no address}) ok"
  done 3< "$TARGETS"

  step "Writing the new pair to $KV"
  jq --rawfile pub "$TMP/new_key.pub" --rawfile priv "$TMP/new_key" --arg prev "$CUR_PUB" \
    '. + {public_key: ($pub | rtrimstr("\n")), private_key: $priv, previous_public_key: $prev}' \
    "$TMP/cur_data.json" > "$TMP/put1.json"
  vault kv put "$KV" @"$TMP/put1.json" >/dev/null \
    || die "vault kv put failed. Both keys still work on every container; Vault still holds the old pair."
  GOT="$(vault kv get -field=public_key "$KV")"
  [ "$(material "$GOT")" = "$NEW_MAT" ] || die "Vault read-back does not hold the new public key."
  echo "  Vault holds the new pair, with the old public key in previous_public_key."
else
  step "Logging in to every container with the key already in Vault"
  while read -u 3 -r node vmid ip hasold hasnew; do
    a="$(ctip "$node" "$vmid" "$ip")"; r="$(login "$a" "$TMP/new_key")"
    [ "$r" = ok ] || die "Vault's key: CT $vmid (${a:-no address}) answered '$r'. Append it to $AUTH on that container, then re-run."
    echo "  CT $vmid (${a:-no address}) ok"
  done 3< "$TARGETS"
fi

step "Removing the old public key"
while read -u 3 -r node vmid ip hasold hasnew; do
  remove_key "$vmid" "$node" "$OLD_MAT" \
    || die "Could not edit $AUTH on CT $vmid ($(cat "$TMP/remove_key_reason" 2>/dev/null || true); empty means pct exec or ssh failed). The file is unchanged. Vault holds the new pair; re-run to resume."
  echo "  CT $vmid edited"
done 3< "$TARGETS"

step "Reading back"
BAD=0
while read -u 3 -r node vmid ip hasold hasnew; do
  rc=0; has_key "$vmid" "$node" "$OLD_MAT" || rc=$?
  [ "$rc" -eq 1 ] || { warn "CT $vmid: old key still in $AUTH (or unreadable, rc=$rc)"; BAD=$((BAD + 1)); }
  a="$(ctip "$node" "$vmid" "$ip")"
  r="$(login "$a" "$TMP/new_key")"
  [ "$r" = ok ] || { warn "CT $vmid: new key answered '$r'"; BAD=$((BAD + 1)); }
  if [ -f "$TMP/old_key" ]; then
    r="$(login "$a" "$TMP/old_key")"
    [ "$r" = denied ] || { warn "CT $vmid: old private key answered '$r', expected denied"; BAD=$((BAD + 1)); }
  fi
done 3< "$TARGETS"
[ "$BAD" -eq 0 ] || die "$BAD read-back check(s) failed. previous_public_key stays in Vault; fix and re-run."
OLDCHECK="old private key refused"; [ -f "$TMP/old_key" ] || OLDCHECK="old key material absent from $AUTH (old private key not tested on a resume)"
echo "  $NTARGET containers: new key logs in; $OLDCHECK."

step "Clearing previous_public_key from Vault"
# Re-read, so a field another writer added since the start survives; drop only previous_public_key.
vault kv get -format=json "$KV" | jq '.data.data | del(.previous_public_key)' > "$TMP/put2.json" \
  || die "Could not read $KV to clear previous_public_key. The rotation is done; delete that field by hand."
vault kv put "$KV" @"$TMP/put2.json" >/dev/null \
  || die "Could not clear previous_public_key. The rotation is done; delete that field by hand."
echo "  done."

if [ "$LOCAL" -eq 1 ]; then
  step "Replacing $LOCAL_KEY"
  mkdir -p "$(dirname "$LOCAL_KEY")"
  # No backup: the old private key is refused everywhere now, and a copy would leave it
  # outside this script's 0700 directory.
  cat "$TMP/new_key" > "$LOCAL_KEY"
  cat "$TMP/new_key.pub" > "$LOCAL_KEY.pub"
fi

echo
echo "Rotated kv/iac/lxc-ssh: examined $TOTAL containers on ${#NODES[@]} nodes, rotated $NTARGET, ${#SKIPPED[@]} did not list the old key ($PROBED)."
echo "Next: delete other copies of the old private key (a Mac backup, a runner file); they open nothing now."
