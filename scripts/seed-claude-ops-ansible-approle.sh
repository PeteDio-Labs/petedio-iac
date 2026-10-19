#!/usr/bin/env bash
# seed-claude-ops-ansible-approle.sh — mint a secret_id for the ansible-247 AppRole and deliver
# it, with the role_id, to claude-ops's iac clone on claude-247 (PET-674).
#
# WHY: every scripts/deploy-*.sh logs in from .secrets/ansible.{role_id,secret_id}. The Mac
# holds those files (docs/runbooks/vault-seed.md), and 247 did not, so deploy-plane.sh stopped
# there on 2026-10-19 (PET-667). Pedro asked for 247 to run Ansible the way the Mac does. This
# script lands the same two files, under the same names, so no deploy script changes.
#
# ⚠ A ROLE OF ITS OWN, NOT A COPY OF THE MAC'S. The files hold ansible-247's role_id and a
# secret_id minted for 247 alone. environments/homelab/vault-config defines the role:
#   policy ansible-247: the ansible policy without kv/admin/*, where the root token and the
#                       unseal material live (PET-531 keeps both off 247).
#   secret_id_bound_cidrs and token_bound_cidrs: 192.168.50.247/32, so the secret_id logs in
#                       from 247 only, and its tokens work from 247 only.
# The Mac's secret_id is never read, copied or rotated here.
#
# Run it on the Mac, on Pedro's word (PET-511), after scripts/apply-vault-config.sh has created
# the role. It needs root on pve03, the node that hosts CT 247 (PET-561).
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No
#   interactive prompt — set one of those first, or this refuses to run.
#
# THE SECRET_ID TRAVELS ON STDIN ONLY. It is never an argument, never printed, and never
# written outside $IAC_CLONE/.secrets/ on 247. The proof at the end logs in on 247 with
# `role_id=@file secret_id=@file`, prints only the token's policies and capabilities, and
# revokes the token it made.
#
# IDEMPOTENT: when 247 already holds files that log in as ansible-247, this script changes
# nothing. When they do not log in, it stops; pass --rotate to replace them. --rotate mints a
# new secret_id, proves it, and then destroys the old one by the accessor this script recorded.
#
# Usage:
#   ./scripts/seed-claude-ops-ansible-approle.sh [--rotate]
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

PVE03="root@192.168.50.10"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
pve03() { ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$PVE03" "$@"; }
CT=247
OPS_USER=claude-ops
IAC_CLONE="${IAC_CLONE:-/home/claude-ops/work/petedio/workspace/iac}"
DEST="$IAC_CLONE/.secrets"
ROLE=ansible-247
CIDR=192.168.50.247/32

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
# Run a shell command in CT 247 as claude-ops, in a login shell so HOME and PATH are its own.
# The command is a fixed string from this script and never carries a secret.
as_ops() { pve03 "pct exec $CT -- runuser -l $OPS_USER -c '$1'"; }

# The proof, run on 247 as claude-ops. It logs in from the two files, prints the token's
# policies and two capabilities, and revokes the token. Exit 0 only when every value matches.
PROOF="cd $IAC_CLONE && export VAULT_ADDR=$VAULT_ADDR VAULT_CACERT=$IAC_CLONE/environments/homelab/vault-ca.crt && \
t=\$(vault write -field=token auth/approle/login role_id=@.secrets/ansible.role_id secret_id=@.secrets/ansible.secret_id 2>/dev/null) && [ -n \"\$t\" ] || { echo login=refused; exit 1; }; \
p=\$(VAULT_TOKEN=\$t vault token lookup -format=json | jq -r \".data.policies|sort|join(\\\",\\\")\"); \
s=\$(VAULT_TOKEN=\$t vault token capabilities kv/data/services/plane); \
a=\$(VAULT_TOKEN=\$t vault token capabilities kv/data/admin/probe); \
VAULT_TOKEN=\$t vault token revoke -self >/dev/null 2>&1; \
echo login=ok policies=\$p services=\$s admin=\$a; \
[ \"\$p\" = ansible-247,default ] && [ \"\$s\" = read ] && [ \"\$a\" = deny ]"

for t in vault jq ssh; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root@pve03 accepts."

# Before the mint, not after it: a run that dies here leaves no secret_id behind (PET-561).
step "Checking claude-ops's iac clone on CT $CT"
as_ops "test -f $IAC_CLONE/scripts/deploy-plane.sh" \
  || die "$IAC_CLONE is not an iac clone on CT $CT, or pve03 refused SSH. Set IAC_CLONE to claude-ops's clone of petedio-iac."
as_ops "command -v vault >/dev/null && command -v jq >/dev/null" \
  || die "vault or jq is not on claude-ops's PATH on CT $CT. Deploy the claude-code role with claude_iac_tools_enable true first."
as_ops "cd $IAC_CLONE && git check-ignore -q .secrets/ansible.secret_id" \
  || die "$IAC_CLONE does not ignore .secrets/. Pull main there before anything lands in it."

step "Checking what CT $CT holds already"
HAVE=0
if as_ops "test -e $DEST/ansible.role_id || test -e $DEST/ansible.secret_id"; then
  HAVE=1
  if OUT="$(as_ops "$PROOF")"; then
    echo "  $OUT"
    if [ "$ROTATE" -eq 0 ]; then
      echo "  The files on CT $CT log in as $ROLE. Nothing to do; pass --rotate to replace the secret_id."
      exit 0
    fi
  else
    echo "  ${OUT:-no output}"
    [ "$ROTATE" -eq 1 ] || die "$DEST holds AppRole files that do not log in as $ROLE. Read them on 247, then re-run with --rotate to replace them."
  fi
fi
OLD_ACCESSOR=""
if [ "$HAVE" -eq 1 ]; then
  OLD_ACCESSOR="$(as_ops "cat $DEST/ansible.secret_id_accessor 2>/dev/null" || true)"
fi

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run this from inside the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. This script does not prompt."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Checking the $ROLE role and its policy"
ROLE_JSON="$(vault read -format=json "auth/approle/role/$ROLE" 2>/dev/null)" \
  || die "auth/approle/role/$ROLE does not exist. Apply environments/homelab/vault-config first: ./scripts/apply-vault-config.sh"
[ "$(jq -r '.data.token_policies|sort|join(",")' <<<"$ROLE_JSON")" = "$ROLE" ] \
  || die "$ROLE's token_policies are not exactly [$ROLE]. Check vault-config before minting."
[ "$(jq -r '.data.secret_id_bound_cidrs|join(",")' <<<"$ROLE_JSON")" = "$CIDR" ] \
  || die "$ROLE's secret_id_bound_cidrs are not exactly [$CIDR]."
[ "$(jq -r '.data.token_bound_cidrs|join(",")' <<<"$ROLE_JSON")" = "$CIDR" ] \
  || die "$ROLE's token_bound_cidrs are not exactly [$CIDR]."
unset ROLE_JSON
if vault policy read "$ROLE" | grep -q 'kv/[a-z]*/admin'; then
  die "Policy $ROLE names kv/admin. It must not; see environments/homelab/vault-config/policies.tf."
fi
ROLE_ID="$(vault read -field=role_id "auth/approle/role/$ROLE/role-id")"
[ -n "$ROLE_ID" ] || die "Vault returned no role_id for $ROLE."
echo "  policies=$ROLE, both CIDR lists=$CIDR, no kv/admin path."

step "Minting a secret_id for $ROLE"
MINT_JSON="$(vault write -format=json -f "auth/approle/role/$ROLE/secret-id" \
  metadata='{"host":"claude-247","user":"claude-ops","pet":"PET-674"}')"
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
    as_ops "rm -f $DEST/ansible.role_id $DEST/ansible.secret_id $DEST/ansible.secret_id_accessor" \
      && echo "  Removed the unproven files from $DEST on CT $CT." >&2
  fi
  if vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$ACCESSOR" >/dev/null 2>&1; then
    echo "  Destroyed the unproven secret_id (accessor $ACCESSOR)." >&2
  else
    echo "  Could not destroy accessor $ACCESSOR. Run: vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$ACCESSOR" >&2
  fi
}
trap destroy_unless_proven EXIT

step "Delivering to $DEST on CT $CT (stdin only, never an argument)"
as_ops "mkdir -p $DEST && chmod 700 $DEST"
DELIVERED=1
# `cat` reads fd 0 as the container inherits it; CT 247 is unprivileged, so it cannot reopen
# the host-owned pipe as /dev/stdin (PET-561). Each file is mode 0600 from its first byte, and
# the mv swaps it into place whole. printf '%s' writes no trailing newline.
deliver() {
  as_ops "umask 0177 && cat > $DEST/$1.new && mv -f $DEST/$1.new $DEST/$1"
}
printf '%s' "$ROLE_ID" | deliver ansible.role_id
printf '%s' "$SECRET_ID" | deliver ansible.secret_id
unset SECRET_ID
# The accessor is not a credential: it destroys or looks up this secret_id only for a token
# that already holds that right. It lets a later --rotate remove this secret_id.
printf '%s' "$ACCESSOR" | deliver ansible.secret_id_accessor

step "Verifying on CT $CT (owner, mode and size only, never the contents)"
for f in ansible.role_id ansible.secret_id; do
  read -r LEN MODE OWNER <<<"$(as_ops "stat -c \"%s %a %U\" $DEST/$f")"
  [ "${LEN:-0}" -gt 0 ] || die "$DEST/$f is empty on CT $CT."
  [ "$MODE" = "600" ] && [ "$OWNER" = "$OPS_USER" ] \
    || die "$DEST/$f is mode $MODE, owner $OWNER. Expected 600, $OPS_USER."
  echo "  $f: $LEN bytes, mode $MODE, $OWNER."
done

step "Proving the login from CT $CT, as $OPS_USER"
OUT="$(as_ops "$PROOF")" || die "The login on CT $CT failed: ${OUT:-no output}"
echo "  $OUT"
PROVEN=1

if [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$ACCESSOR" ]; then
  step "Destroying the replaced secret_id"
  if vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$OLD_ACCESSOR" >/dev/null 2>&1; then
    echo "  destroyed accessor $OLD_ACCESSOR."
  else
    echo "  Could not destroy accessor $OLD_ACCESSOR. It may be gone already; check with:"
    echo "  vault list auth/approle/role/$ROLE/secret-id"
  fi
fi

step "Next"
cat <<TXT
  Record the accessor on PET-674: $ACCESSOR

  claude-ops on 247 can now run the deploy scripts from $IAC_CLONE, for example:
    ./scripts/deploy-plane.sh

  To take the access back, destroy the secret_id on the Mac:
    vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$ACCESSOR
TXT
