#!/usr/bin/env bash
# apply-vault-config.sh — apply the environments/homelab/vault-config workspace with the
# review baked in as code. The vault-config workspace (KV mount, policies, AppRoles, the
# GitHub-OIDC JWT auth role) is operator-applied — CI never touches it — because it needs a
# privileged Vault token. This plans first and REFUSES to apply if the plan would destroy
# anything, so routine changes (e.g. a JWT bound_claims edit) apply safely and unattended.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
set -euo pipefail

# ⚠ DESTROYS ARE OPT-IN, PER INVOCATION. The guard below refuses any plan that removes
# a live resource, because this root holds the policies and auth roles that gate every
# credential in the lab, and a removal here is silent until something cannot mint.
#
# A decommission is a legitimate removal, though, and before PET-370 there was no way
# to complete one: the script refused and offered no path, so a merged teardown sat
# unapplied and `main` disagreed with live Vault. `--allow-destroy` is that path.
#
# It is a FLAG, not an environment or repo variable, and deliberately so. CI's
# plan-gate takes ALLOW_DESTROY as a repo variable, which stays on until somebody
# remembers to turn it off — PET-366 left that window open for two minutes and only
# because it was being watched. A flag cannot be left on: it is spent when the command
# ends.
ALLOW_DESTROY=0
for arg in "$@"; do
  case "$arg" in
    --allow-destroy) ALLOW_DESTROY=1 ;;
    -h|--help)
      printf 'usage: %s [--allow-destroy]\n\n' "${0##*/}"
      printf '  --allow-destroy  apply a plan that removes resources. Off by default;\n'
      printf '                   the plan is printed and confirmed before anything runs.\n'
      exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
VCDIR="$HOMELAB/vault-config"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
[ -d "$VCDIR" ] || die "vault-config dir not found: $VCDIR"
cd "$VCDIR"

step "Credentials"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."
# vault-config state lives in the MinIO S3 backend
AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio)"; export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio)"; export AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || die "could not read kv/iac/minio."

step "init + plan"
terraform init -reconfigure -input=false >/tmp/vc-init.log 2>&1 || { tail -15 /tmp/vc-init.log; die "terraform init failed."; }
terraform plan -input=false -no-color -out=tfplan 2>&1 | tee /tmp/vc-plan.txt

step "review (as code) — refuse to apply on any destroy"
if grep -qE '^No changes\.' /tmp/vc-plan.txt; then
  echo "No changes — nothing to apply."; exit 0
fi
PLAN_LINE="$(grep -E '^Plan: ' /tmp/vc-plan.txt | tail -1 || true)"
[ -n "$PLAN_LINE" ] || die "no 'Plan:' summary — inspect /tmp/vc-plan.txt."
DES="$(sed -E 's/.* ([0-9]+) to destroy.*/\1/' <<<"$PLAN_LINE")"
echo "  $PLAN_LINE"
if [ "$DES" != "0" ]; then
  if [ "$ALLOW_DESTROY" != "1" ]; then
    printf '\n\033[1;31mThis plan REMOVES %s resource(s):\033[0m\n' "$DES"
    grep -E '^  # .* will be destroyed' /tmp/vc-plan.txt | sed 's/^  # /  /; s/ will be destroyed//' || true
    die "not applying. Review /tmp/vc-plan.txt, then re-run with --allow-destroy if every line above should go."
  fi

  # ⚠ NAME WHAT GOES, AND MAKE SOMEONE READ IT. The count alone is the thing that
  # lets a wrong plan through: "3 to destroy" looks the same whether it is three
  # Co-latro roles or three that still gate a live service.
  step "review the removals"
  printf '\033[1;31mThis plan REMOVES %s resource(s):\033[0m\n' "$DES"
  grep -E '^  # .* will be destroyed' /tmp/vc-plan.txt | sed 's/^  # /  /; s/ will be destroyed//' || true
  printf '\nEvery line above will be deleted from live Vault. Type the number %s to proceed: ' "$DES"
  read -r CONFIRM
  [ "$CONFIRM" = "$DES" ] || die "not confirmed — nothing applied."
fi

if [ "$DES" = "0" ]; then
  step "apply (guard passed: 0 to destroy)"
else
  step "apply ($DES to destroy, confirmed)"
fi
terraform apply -input=false tfplan
echo "vault-config applied."
