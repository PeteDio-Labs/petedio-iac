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
# The new files are staged as *.new, proved, and only then swapped into place, so a failed
# --rotate leaves the old secret_id working and reachable.
#
# Testing: scripts/test-seed-vault-snapshot-approle.sh runs the whole flow against stubs.
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
# succeeds and every value matches. $1 is "" for the live files and ".new" for the staged ones.
proof_cmd() {
  printf %s "export VAULT_ADDR=$HOST_VAULT_ADDR VAULT_CACERT=$HOST_VAULT_CACERT; \
t=\$(vault write -field=token auth/approle/login role_id=@$DEST/role_id$1 secret_id=@$DEST/secret_id$1 2>/dev/null) && [ -n \"\$t\" ] || { echo login=refused; exit 1; }; \
export VAULT_TOKEN=\$t; \
p=\$(vault token lookup -field=policies 2>/dev/null); \
s=\$(vault token capabilities sys/storage/raft/snapshot 2>/dev/null); \
k=\$(vault token capabilities kv/data/services/vault-snapshots 2>/dev/null); \
a=\$(vault token capabilities kv/data/admin/probe 2>/dev/null); \
vault token revoke -self >/dev/null 2>&1 || { echo revoke=failed policies=\$p; exit 1; }; \
echo login=ok policies=\$p snapshot=\$s minio_creds=\$k admin=\$a; \
[ \"\$p\" = '[default vault-snapshot]' ] && [ \"\$s\" = read ] && [ \"\$k\" = read ] && [ \"\$a\" = deny ]"
}

# run_proof SUFFIX sets PROOF_OUT and returns the proof's exit code. An SSH failure (255)
# stops the script, because it says nothing about the credentials.
run_proof() {
  local rc=0
  PROOF_OUT="$(as_host "$(proof_cmd "$1")")" || rc=$?
  [ "$rc" -ne 255 ] || die "SSH to $SNAP_HOST failed during the proof (exit 255). Nothing was proved; fix the connection and run this again."
  return "$rc"
}

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

# host_has returns 0 when 223 holds either credential file and 1 when it holds neither. Any
# other exit code, an SSH failure (255) included, stops the script: a dropped connection must
# not read as "file absent" and send the script on to mint over live credentials.
host_has() {
  local rc=0
  as_host "test -e $DEST/role_id || test -e $DEST/secret_id" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "SSH to $SNAP_HOST failed while looking for $DEST (exit $rc). Fix the connection and run this again." ;;
  esac
}

# host_read NAME prints $DEST/NAME, or nothing when the file is absent. An SSH failure stops the script.
host_read() {
  as_host "if test -e $DEST/$1; then cat $DEST/$1; fi" \
    || die "SSH to $SNAP_HOST failed while reading $DEST/$1."
}

# deliver NAME writes stdin to $DEST/NAME.new on 223, mode 0600 from the first byte. The swap
# into place happens only after the proof passes.
deliver() {
  as_host "umask 0177 && cat > $DEST/$1.new"
}

for t in vault jq ssh; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -z "$SNAP_SSH_KEY" ] || [ -f "$SNAP_SSH_KEY" ] || die "No SSH key at $SNAP_SSH_KEY. Unset SNAP_SSH_KEY or point it at the key $SNAP_HOST accepts."

# Before the mint, not after it: a run that dies here leaves no secret_id behind.
step "Checking $SNAP_HOST"
as_host "command -v vault >/dev/null && test -d /opt/vault/tls" \
  || die "Cannot reach $SNAP_HOST, or it has no vault CLI. Check SSH and that the vault-unseal and configure-vault playbooks ran."

step "Checking what 223 holds already"
HAVE=0; OLD_LOGS_IN=0
if host_has; then
  HAVE=1
  if run_proof ""; then
    OLD_LOGS_IN=1
    echo "  $PROOF_OUT"
    if [ "$ROTATE" -eq 0 ] && [ -z "$(host_read secret_id_accessor.old)" ]; then
      echo "  The files on 223 log in as $ROLE. Nothing to do; pass --rotate to replace the secret_id."
      exit 0
    fi
  else
    echo "  ${PROOF_OUT:-no output}"
    [ "$ROTATE" -eq 1 ] || die "$DEST holds AppRole files that fail the proof above. When login=refused, read them on 223, then re-run with --rotate to replace them."
  fi
fi
OLD_ACCESSOR=""
if [ "$HAVE" -eq 1 ]; then
  OLD_ACCESSOR="$(host_read secret_id_accessor)"
fi
# An accessor a past --rotate replaced but could not destroy. Its secret_id may still log in.
PENDING="$(host_read secret_id_accessor.old)"

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

# The trap is set before the mint, so a mint that returns a secret_id and no accessor still
# leaves nothing that can log in. Any exit before the proof passes removes the staged files
# and destroys the new secret_id, by accessor or, with none, by the secret_id on stdin. The
# live files are never touched until the proof passes, so a failed --rotate leaves the old
# secret_id working and reachable.
SECRET_ID=""; ACCESSOR=""; STAGED=0; PROVEN=0
cleanup_unproven() {
  [ "$PROVEN" -eq 1 ] && return 0
  if [ "$STAGED" -eq 1 ]; then
    as_host "rm -f $DEST/role_id.new $DEST/secret_id.new $DEST/secret_id_accessor.new" \
      && echo "  Removed the staged files from $DEST on 223." >&2
  fi
  if [ -n "$ACCESSOR" ]; then
    if vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$ACCESSOR" >/dev/null 2>&1; then
      echo "  Destroyed the unproven secret_id (accessor $ACCESSOR)." >&2
    else
      echo "  Could not destroy accessor $ACCESSOR. Run: vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$ACCESSOR" >&2
    fi
  elif [ -n "$SECRET_ID" ]; then
    if printf '{"secret_id":"%s"}' "$SECRET_ID" | vault write "auth/approle/role/$ROLE/secret-id/destroy" - >/dev/null 2>&1; then
      echo "  Destroyed the unproven secret_id (Vault returned no accessor for it)." >&2
    else
      echo "  Vault returned no accessor and refused to destroy the new secret_id. List accessors: vault list auth/approle/role/$ROLE/secret-id" >&2
    fi
  fi
}
trap cleanup_unproven EXIT

step "Minting a secret_id for $ROLE"
MINT_JSON="$(vault write -format=json -f "auth/approle/role/$ROLE/secret-id" \
  metadata='{"host":"vault-223","pet":"PET-790"}')"
SECRET_ID="$(jq -r '.data.secret_id // empty' <<<"$MINT_JSON")"
ACCESSOR="$(jq -r '.data.secret_id_accessor // empty' <<<"$MINT_JSON")"
unset MINT_JSON
[ -n "$SECRET_ID" ] && [ -n "$ACCESSOR" ] || die "vault write did not return both a secret_id and its accessor."
echo "  accessor $ACCESSOR"

step "Staging in $DEST on 223 (stdin only, never an argument)"
as_host "mkdir -p $DEST && chmod 700 $DEST"
STAGED=1
printf '%s' "$ROLE_ID" | deliver role_id
printf '%s' "$SECRET_ID" | deliver secret_id
unset SECRET_ID
# The accessor is not a credential: it destroys or looks up this secret_id only for a token
# that already holds that right. It lets a later --rotate remove this secret_id.
printf '%s' "$ACCESSOR" | deliver secret_id_accessor

step "Verifying the staged files on 223 (owner, mode and size only, never the contents)"
for f in role_id secret_id; do
  read -r LEN MODE OWNER <<<"$(as_host "stat -c '%s %a %U' $DEST/$f.new")"
  [ "${LEN:-0}" -gt 0 ] || die "$DEST/$f.new is empty on 223."
  [ "$MODE" = "600" ] && [ "$OWNER" = "root" ] \
    || die "$DEST/$f.new is mode $MODE, owner $OWNER. Expected 600, root."
  echo "  $f.new: $LEN bytes, mode $MODE, $OWNER."
done

step "Proving the staged login from 223"
run_proof ".new" || die "The login on 223 failed: ${PROOF_OUT:-no output}"
echo "  $PROOF_OUT"
PROVEN=1

# Record the accessor being replaced BEFORE the swap, so a run that dies from here on still
# leaves a record of the secret_id to destroy.
if [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$ACCESSOR" ]; then
  printf '%s' "$OLD_ACCESSOR" | as_host "umask 0177 && cat > $DEST/secret_id_accessor.old"
fi
step "Swapping the proven files into place"
as_host "cd $DEST && mv -f role_id.new role_id && mv -f secret_id.new secret_id && mv -f secret_id_accessor.new secret_id_accessor"
run_proof "" || die "The swapped files on 223 fail the proof: ${PROOF_OUT:-no output}"
echo "  $PROOF_OUT"

STATUS=0
if [ "$HAVE" -eq 1 ] && [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$ACCESSOR" ]; then
  step "Destroying the replaced secret_id"
  case "$(destroy_accessor "$OLD_ACCESSOR")" in
    destroyed) echo "  destroyed accessor $OLD_ACCESSOR." ;;
    absent)    echo "  accessor $OLD_ACCESSOR was already gone." ;;
    failed)
      die "Vault refused to destroy accessor $OLD_ACCESSOR, so the old secret_id may still log in. It stays recorded in $DEST/secret_id_accessor.old on 223; re-run this script to retry." ;;
    *) die "destroy_accessor returned an unknown verdict." ;;
  esac
  as_host "rm -f $DEST/secret_id_accessor.old"
elif [ "$OLD_LOGS_IN" -eq 1 ]; then
  STATUS=1
  printf '\033[31mWARNING\033[0m %s\n' "223 held working credential files but no secret_id_accessor, so the replaced secret_id is still valid and this script cannot destroy it. List the accessors and destroy the old one: vault list auth/approle/role/$ROLE/secret-id" >&2
fi

step "Next"
cat <<TXT
  Record the accessor on PET-790: $ACCESSOR

  Install the units, then take one snapshot and check that it lands:
    cd ansible && ansible-playbook playbooks/vault-snapshot.yml
    ssh $SNAP_HOST systemctl start vault-snapshot.service
    ssh $SNAP_HOST journalctl -u vault-snapshot.service -n 30
    mc ls <alias>/vault-snapshots   # <alias>: any mc alias for http://192.168.50.221:9000 (mc alias list)

  To take the access back, destroy the secret_id:
    vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$ACCESSOR
TXT
exit "$STATUS"
