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

for t in vault jq ssh ssh-keygen awk; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root on the nodes accepts."
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run from inside the repo or export it."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

material() { awk '{print $2}' <<<"$1"; }
valid_material() { [[ "$1" =~ ^[A-Za-z0-9+/=]{40,}$ ]]; }

# has_key <vmid> <node> <material>: 0 present, 1 absent, anything else is a fault.
has_key() {
  local rc=0
  on_node "$2" "pct exec $1 -- grep -qF '$3' $AUTH" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# login <ip> <keyfile>: prints ok, denied or unreachable.
login() {
  local err rc=0
  err="$(ssh -n -o ConnectTimeout=6 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    -i "$2" "root@$1" true 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then echo ok
  elif grep -q 'Permission denied' <<<"$err"; then echo denied
  else echo unreachable
  fi
}

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
    ip="$(sed -n 's/^net0:.*[,]ip=\([0-9.]*\)\/.*/\1/p' <<<"$cfg" | head -1)"
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
  if [ "$hasold" -eq 0 ] && [ "$hasnew" -eq 0 ]; then SKIPPED+=("$vmid"); continue; fi
  if [ "$ip" = none ]; then FAULTS+=("$vmid:no-static-ip"); continue; fi
  printf '%s %s %s %s %s\n' "$node" "$vmid" "$ip" "$hasold" "$hasnew" >> "$TARGETS"
  echo "  CT $vmid ($ip): old=$hasold new=$hasnew"
done 3< "$ROWS"
NTARGET="$(grep -c . "$TARGETS" || true)"
echo "  $NTARGET trust the key; ${#SKIPPED[@]} trust neither (${SKIPPED[*]:-none}); ${#STOPPED[@]} not running (${STOPPED[*]:-none}); ${#FAULTS[@]} unreadable (${FAULTS[*]:-none})."
[ "${#FAULTS[@]}" -eq 0 ] || die "Could not read or address: ${FAULTS[*]}. Fix these first; nothing was changed."
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

  step "Appending the new public key"
  while read -u 3 -r node vmid ip hasold hasnew; do
    if [ "$hasnew" -eq 1 ]; then echo "  CT $vmid already has it"; continue; fi
    printf '%s\n' "$NEW_PUB" | on_node "$node" "pct exec $vmid -- sh -c 'cat >> $AUTH'" \
      || die "Could not append to CT $vmid. Both keys are still valid everywhere; Vault is unchanged."
    echo "  CT $vmid appended"
  done 3< "$TARGETS"

  step "Logging in to every container with the NEW key"
  while read -u 3 -r node vmid ip hasold hasnew; do
    r="$(login "$ip" "$TMP/new_key")"
    [ "$r" = ok ] || die "New key: CT $vmid ($ip) answered '$r'. Stopped before Vault changed; the old key still works. A re-run generates another pair, so remove stray lines from $AUTH by hand if this repeats."
    echo "  CT $vmid ($ip) ok"
  done 3< "$TARGETS"

  step "Writing the new pair to $KV"
  printf '%s' "$NEW_PUB" > "$TMP/new_pub_value"
  printf '%s' "$CUR_PUB" > "$TMP/old_pub_value"
  vault kv put "$KV" public_key=@"$TMP/new_pub_value" private_key=@"$TMP/new_key" \
    previous_public_key=@"$TMP/old_pub_value" >/dev/null \
    || die "vault kv put failed. Both keys still work on every container; Vault still holds the old pair."
  GOT="$(vault kv get -field=public_key "$KV")"
  [ "$(material "$GOT")" = "$NEW_MAT" ] || die "Vault read-back does not hold the new public key."
  echo "  Vault holds the new pair, with the old public key in previous_public_key."
else
  step "Logging in to every container with the key already in Vault"
  while read -u 3 -r node vmid ip hasold hasnew; do
    r="$(login "$ip" "$TMP/new_key")"
    [ "$r" = ok ] || die "Vault's key: CT $vmid ($ip) answered '$r'. Append it to $AUTH on that container, then re-run."
    echo "  CT $vmid ($ip) ok"
  done 3< "$TARGETS"
fi

step "Removing the old public key"
while read -u 3 -r node vmid ip hasold hasnew; do
  on_node "$node" "pct exec $vmid -- sh -c 'f=$AUTH; { grep -vF \"$OLD_MAT\" \$f || true; } > \$f.rot && cat \$f.rot > \$f && rm -f \$f.rot'" \
    || die "Could not edit $AUTH on CT $vmid. Vault holds the new pair; re-run to resume."
  echo "  CT $vmid edited"
done 3< "$TARGETS"

step "Reading back"
BAD=0
while read -u 3 -r node vmid ip hasold hasnew; do
  rc=0; has_key "$vmid" "$node" "$OLD_MAT" || rc=$?
  [ "$rc" -eq 1 ] || { warn "CT $vmid: old key still in $AUTH (or unreadable, rc=$rc)"; BAD=$((BAD + 1)); }
  r="$(login "$ip" "$TMP/new_key")"
  [ "$r" = ok ] || { warn "CT $vmid: new key answered '$r'"; BAD=$((BAD + 1)); }
  if [ -f "$TMP/old_key" ]; then
    r="$(login "$ip" "$TMP/old_key")"
    [ "$r" = denied ] || { warn "CT $vmid: old private key answered '$r', expected denied"; BAD=$((BAD + 1)); }
  fi
done 3< "$TARGETS"
[ "$BAD" -eq 0 ] || die "$BAD read-back check(s) failed. previous_public_key stays in Vault; fix and re-run."
OLDCHECK="old private key refused"; [ -f "$TMP/old_key" ] || OLDCHECK="old key material absent from $AUTH (old private key not tested on a resume)"
echo "  $NTARGET containers: new key logs in; $OLDCHECK."

[ "${#STOPPED[@]}" -eq 0 ] || die "Not rotated, containers not running: ${STOPPED[*]}. Start them and re-run; previous_public_key stays in Vault so the re-run resumes."

step "Clearing previous_public_key from Vault"
printf '%s' "$(cat "$TMP/new_key.pub")" > "$TMP/new_pub_value"
vault kv put "$KV" public_key=@"$TMP/new_pub_value" private_key=@"$TMP/new_key" >/dev/null \
  || die "Could not clear previous_public_key. The rotation is done; delete that field by hand."
echo "  done."

if [ "$LOCAL" -eq 1 ]; then
  step "Replacing $LOCAL_KEY"
  mkdir -p "$(dirname "$LOCAL_KEY")"
  if [ -f "$LOCAL_KEY" ]; then
    cp -p "$LOCAL_KEY" "$LOCAL_KEY.pre-rotation-$(date +%Y%m%d)"
    echo "  old copy kept as $LOCAL_KEY.pre-rotation-$(date +%Y%m%d); delete it when you are done."
  fi
  cat "$TMP/new_key" > "$LOCAL_KEY"
  cat "$TMP/new_key.pub" > "$LOCAL_KEY.pub"
fi

echo
echo "Rotated kv/iac/lxc-ssh: examined $TOTAL containers on ${#NODES[@]} nodes, rotated $NTARGET, ${#SKIPPED[@]} trusted neither key."
echo "Next: other copies of the old private key (a Mac backup, a runner file) still open nothing, but delete them."
