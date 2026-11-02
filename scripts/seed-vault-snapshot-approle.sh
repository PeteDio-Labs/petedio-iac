#!/usr/bin/env bash
# seed-vault-snapshot-approle.sh — mint a secret_id for the vault-snapshot AppRole and place it,
# with the role_id, in /etc/vault-snapshot/ on the Vault host, LXC 223 (PET-790).
#
# WHY: roles/vault-snapshot reads role_id and secret_id from /etc/vault-snapshot/ and the
# playbook header says the operator seeds them "out-of-band". No checked-in script did, and the
# working agreement forbids placing a credential by hand, so 223 ran with no snapshot timer and
# Vault had no off-host backup. This script is that step.
#
# Run it on the Mac, on Pedro's word (PET-511), after scripts/apply-vault-config.sh has created
# the vault-snapshot role. Then run ansible/playbooks/vault-snapshot.yml, then
# `systemctl start vault-snapshot.service` on 223. The "Next" block at the end lists the steps.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#   223 access:  ssh as root@192.168.50.223. Set SNAP_SSH_KEY to use a specific key.
#
# THE SECRET_ID TRAVELS ON STDIN ONLY. It is never an argument, never printed, and lands only in
# /etc/vault-snapshot/secret_id (root, mode 0600). The proof at the end logs in on 223 the way
# the snapshot script does, with `key=@file`, prints the token's policies and three
# capabilities, and revokes the token it made.
#
# IDEMPOTENT: when 223 already holds files that log in as vault-snapshot, this script changes
# nothing. When they do not log in, it stops; pass --rotate to replace them. --rotate mints a
# new secret_id, proves it, and then destroys the old one by the accessor recorded in
# secret_id_accessor. When that destroy fails, the run exits non-zero and keeps the old
# accessor in secret_id_accessor.old; the next run retries it before anything else.
#
# Usage:
#   ./scripts/seed-vault-snapshot-approle.sh [--rotate]
#
# Testing: SEED_SNAPSHOT_SOURCE_ONLY=1 defines the functions and runs nothing.
# scripts/test-seed-vault-snapshot-approle.sh runs the whole flow against stubs.
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

SNAP_HOST="${SNAP_HOST:-root@192.168.50.223}"
SNAP_SSH_KEY="${SNAP_SSH_KEY:-}"
# Match ansible/roles/vault-snapshot/defaults/main.yml.
DEST="${SNAP_CRED_DIR:-/etc/vault-snapshot}"
HOST_VAULT_ADDR="${SNAP_HOST_VAULT_ADDR:-https://192.168.50.223:8200}"
HOST_VAULT_CACERT="${SNAP_HOST_VAULT_CACERT:-/opt/vault/tls/vault.crt}"
ROLE=vault-snapshot

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Run a fixed command string on 223. It never carries a secret. Stdin passes through to it.
as_host() {
  local opts=(-o ConnectTimeout=8 -o BatchMode=yes)
  [ -z "$SNAP_SSH_KEY" ] || opts+=(-o IdentitiesOnly=yes -i "$SNAP_SSH_KEY")
  ssh "${opts[@]}" "$SNAP_HOST" "$1"
}

# The proof, run on 223. It logs in the way the snapshot script does: both values come from
# files through `key=@file`, so neither reaches an argument list. It prints the token's
# policies and three capabilities, and revokes the token. It exits 0 only when the revoke
# succeeds and every value matches.
PROOF="export VAULT_ADDR=$HOST_VAULT_ADDR VAULT_CACERT=$HOST_VAULT_CACERT; \
t=\$(vault write -field=token auth/approle/login role_id=@$DEST/role_id secret_id=@$DEST/secret_id 2>/dev/null) && [ -n \"\$t\" ] || { echo login=refused; exit 1; }; \
export VAULT_TOKEN=\$t; \
p=\$(vault token lookup -field=policies 2>/dev/null); \
s=\$(vault token capabilities sys/storage/raft/snapshot 2>/dev/null); \
k=\$(vault token capabilities kv/data/services/vault-snapshots 2>/dev/null); \
a=\$(vault token capabilities kv/data/admin/probe 2>/dev/null); \
vault token revoke -self >/dev/null 2>&1 || { echo revoke=failed policies=\$p; exit 1; }; \
echo login=ok policies=\$p snapshot=\$s minio_creds=\$k admin=\$a; \
[ \"\$p\" = '[default vault-snapshot]' ] && [ \"\$s\" = read ] && [ \"\$k\" = read ] && [ \"\$a\" = deny ]"

# Destroy one secret_id by its accessor, and print one verdict: destroyed, absent or failed.
# Vault answers an accessor it does not hold with "failed to find accessor entry", and that
# counts as absent. Any other refusal, a sealed Vault included, is a failure.
destroy_accessor() {
  local err
  if err="$(vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$1" 2>&1 >/dev/null)"; then
    echo destroyed
  elif printf '%s' "$err" | grep -q 'failed to find accessor entry'; then
    echo absent
  else
    echo failed
  fi
}

# deliver NAME writes stdin to $DEST/NAME on 223, mode 0600 from the first byte, swapped in whole.
deliver() {
  as_host "umask 0177 && cat > $DEST/$1.new && mv -f $DEST/$1.new $DEST/$1"
}

[ -z "${SEED_SNAPSHOT_SOURCE_ONLY:-}" ] || return 0 2>/dev/null || exit 0

for t in vault jq ssh; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -z "$SNAP_SSH_KEY" ] || [ -f "$SNAP_SSH_KEY" ] || die "No SSH key at $SNAP_SSH_KEY. Unset SNAP_SSH_KEY or point it at the key $SNAP_HOST accepts."

# Before the mint, not after it: a run that dies here leaves no secret_id behind.
step "Checking $SNAP_HOST"
as_host "command -v vault >/dev/null && test -d /opt/vault/tls" \
  || die "Cannot reach $SNAP_HOST, or it has no vault CLI. Check SSH and that the vault-unseal and configure-vault playbooks ran."

step "Checking what 223 holds already"
HAVE=0
if as_host "test -e $DEST/role_id || test -e $DEST/secret_id"; then
  HAVE=1
  if OUT="$(as_host "$PROOF")"; then
    echo "  $OUT"
    if [ "$ROTATE" -eq 0 ] && [ -z "$(as_host "cat $DEST/secret_id_accessor.old 2>/dev/null" || true)" ]; then
      echo "  The files on 223 log in as $ROLE. Nothing to do; pass --rotate to replace the secret_id."
      exit 0
    fi
  else
    echo "  ${OUT:-no output}"
    [ "$ROTATE" -eq 1 ] || die "$DEST holds AppRole files that fail the proof above. When login=refused, read them on 223, then re-run with --rotate to replace them."
  fi
fi
OLD_ACCESSOR=""
if [ "$HAVE" -eq 1 ]; then
  OLD_ACCESSOR="$(as_host "cat $DEST/secret_id_accessor 2>/dev/null" || true)"
fi
# An accessor a past --rotate replaced but could not destroy. Its secret_id may still log in.
PENDING="$(as_host "cat $DEST/secret_id_accessor.old 2>/dev/null" || true)"

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run this from inside the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. This script does not prompt."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Checking the $ROLE role"
ROLE_JSON="$(vault read -format=json "auth/approle/role/$ROLE" 2>/dev/null)" \
  || die "auth/approle/role/$ROLE does not exist. Apply environments/homelab/vault-config first: ./scripts/apply-vault-config.sh"
[ "$(jq -r '.data.token_policies|sort|join(",")' <<<"$ROLE_JSON")" = "$ROLE" ] \
  || die "$ROLE's token_policies are not exactly [$ROLE]. Check vault-config before minting."
unset ROLE_JSON
ROLE_ID="$(vault read -field=role_id "auth/approle/role/$ROLE/role-id")"
[ -n "$ROLE_ID" ] || die "Vault returned no role_id for $ROLE."
echo "  token_policies=[$ROLE]."

if [ -n "$PENDING" ]; then
  step "Destroying the secret_id a past --rotate left behind (accessor $PENDING)"
  case "$(destroy_accessor "$PENDING")" in
    destroyed|absent)
      as_host "rm -f $DEST/secret_id_accessor.old"
      echo "  gone." ;;
    failed)
      die "Vault refused to destroy accessor $PENDING. It stays recorded on 223; re-run this script once Vault answers." ;;
    *) die "destroy_accessor returned an unknown verdict." ;;
  esac
  if [ "$ROTATE" -eq 0 ] && [ "$HAVE" -eq 1 ]; then
    exit 0
  fi
fi

step "Minting a secret_id for $ROLE"
MINT_JSON="$(vault write -format=json -f "auth/approle/role/$ROLE/secret-id" \
  metadata='{"host":"vault-223","pet":"PET-790"}')"
SECRET_ID="$(jq -r '.data.secret_id // empty' <<<"$MINT_JSON")"
ACCESSOR="$(jq -r '.data.secret_id_accessor // empty' <<<"$MINT_JSON")"
unset MINT_JSON
[ -n "$SECRET_ID" ] && [ -n "$ACCESSOR" ] || die "vault write did not return a secret_id."
echo "  accessor $ACCESSOR"

# Any exit before the proof passes destroys this secret_id, so a failed run leaves nothing
# that can log in.
PROVEN=0
DELIVERED=0
destroy_unless_proven() {
  [ "$PROVEN" -eq 1 ] && return 0
  if [ "$DELIVERED" -eq 1 ]; then
    as_host "rm -f $DEST/role_id $DEST/secret_id $DEST/secret_id_accessor" \
      && echo "  Removed the unproven files from $DEST on 223." >&2
  fi
  if vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$ACCESSOR" >/dev/null 2>&1; then
    echo "  Destroyed the unproven secret_id (accessor $ACCESSOR)." >&2
  else
    echo "  Could not destroy accessor $ACCESSOR. Run: vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$ACCESSOR" >&2
  fi
}
trap destroy_unless_proven EXIT

step "Delivering to $DEST on 223 (stdin only, never an argument)"
as_host "mkdir -p $DEST && chmod 700 $DEST"
DELIVERED=1
# Record the accessor being replaced BEFORE its files are overwritten, so a run that dies
# from here on still leaves a record of the secret_id to destroy.
if [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$ACCESSOR" ]; then
  printf '%s' "$OLD_ACCESSOR" | deliver secret_id_accessor.old
fi
printf '%s' "$ROLE_ID" | deliver role_id
printf '%s' "$SECRET_ID" | deliver secret_id
unset SECRET_ID
# The accessor is not a credential: it destroys or looks up this secret_id only for a token
# that already holds that right. It lets a later --rotate remove this secret_id.
printf '%s' "$ACCESSOR" | deliver secret_id_accessor

step "Verifying on 223 (owner, mode and size only, never the contents)"
for f in role_id secret_id; do
  read -r LEN MODE OWNER <<<"$(as_host "stat -c '%s %a %U' $DEST/$f")"
  [ "${LEN:-0}" -gt 0 ] || die "$DEST/$f is empty on 223."
  [ "$MODE" = "600" ] && [ "$OWNER" = "root" ] \
    || die "$DEST/$f is mode $MODE, owner $OWNER. Expected 600, root."
  echo "  $f: $LEN bytes, mode $MODE, $OWNER."
done

step "Proving the login from 223"
OUT="$(as_host "$PROOF")" || die "The login on 223 failed: ${OUT:-no output}"
echo "  $OUT"
PROVEN=1

if [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$ACCESSOR" ]; then
  step "Destroying the replaced secret_id"
  case "$(destroy_accessor "$OLD_ACCESSOR")" in
    destroyed) echo "  destroyed accessor $OLD_ACCESSOR." ;;
    absent)    echo "  accessor $OLD_ACCESSOR was already gone." ;;
    failed)
      die "Vault refused to destroy accessor $OLD_ACCESSOR, so the old secret_id may still log in. It stays recorded in $DEST/secret_id_accessor.old on 223; re-run this script to retry." ;;
    *) die "destroy_accessor returned an unknown verdict." ;;
  esac
  as_host "rm -f $DEST/secret_id_accessor.old"
fi

step "Next"
cat <<TXT
  Record the accessor on PET-790: $ACCESSOR

  Install the units, then take one snapshot and check that it lands:
    cd ansible && ansible-playbook playbooks/vault-snapshot.yml
    ssh $SNAP_HOST systemctl start vault-snapshot.service
    ssh $SNAP_HOST journalctl -u vault-snapshot.service -n 30
    mc ls <minio-alias>/vault-snapshots

  To take the access back, destroy the secret_id:
    vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$ACCESSOR
TXT
