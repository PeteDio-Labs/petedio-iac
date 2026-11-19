#!/usr/bin/env bash
# deploy-vault-seal.sh — write the KMS seal block and its credentials onto 223 (docs/runbooks/vault-kms-seal.md).
#
# The credentials come from the macOS Keychain (placed by seed-vault-kms.sh) and go to Ansible as
# extra-vars. They never reach the repo, argv or a CI runner. Operator-run, on purpose: no workflow
# calls vault/configure-vault.yml with these values.
#
#   --key-id ID    the KMS key id printed by seed-vault-kms.sh (required)
#   anything else is passed to ansible-playbook, for example --check
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/ansible"
KEY_ID=""; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --key-id) KEY_ID="${2:?--key-id needs a value}"; shift 2 ;;
    *) PASS+=("$1"); shift ;;
  esac
done
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
[ -n "$KEY_ID" ] || die "pass --key-id <kms key id>."
for t in ansible-playbook security python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done
AK="$(security find-generic-password -s vault-seal-aws-key-id -w 2>/dev/null || true)"
SK="$(security find-generic-password -s vault-seal-aws-secret -w 2>/dev/null || true)"
[ -n "$AK" ] && [ -n "$SK" ] || die "Keychain items vault-seal-aws-key-id and vault-seal-aws-secret not found. Run scripts/seed-vault-kms.sh first."
umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 -c 'import json,sys;a=sys.stdin.read().split("\n");json.dump({"vault_awskms_key_id":sys.argv[2],"vault_awskms_access_key_id":a[0],"vault_awskms_secret_access_key":a[1]},open(sys.argv[1],"w"))' \
  "$TMP/extra.json" "$KEY_ID" <<<"$AK"$'\n'"$SK"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/vault/configure-vault.yml -e "@$TMP/extra.json" ${PASS[@]+"${PASS[@]}"}
