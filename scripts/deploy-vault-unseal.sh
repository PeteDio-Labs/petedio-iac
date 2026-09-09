#!/usr/bin/env bash
# deploy-vault-unseal.sh — install the Vault unseal watcher on pete-pi-1 (PET-373).
#
# ⚠ WHY A SCRIPT AND NOT A WORKFLOW. Rule 6 asks whether the tooling can already say
# this, and here it cannot. The unseal key lives in the macOS Keychain, which is
# reachable only from this Mac. Ansible has no module that reads it, and putting the
# key anywhere a runner could reach — Vault included — defeats the point: Vault
# cannot hold the key that opens Vault. So the key is fetched here, passed as an
# extra-var, and never written to the repo.
#
# ⚠ WHY NOT TERRAFORM. There is no resource for "a systemd timer on a Raspberry Pi".
# The role is the declaration; this script only carries the one value the role must
# not contain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"
KEYCHAIN_ITEM="${VAULT_UNSEAL_KEYCHAIN_ITEM:-vault-unseal-key}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in ansible-playbook security; do
  command -v "$t" >/dev/null || die "$t not in PATH."
done

step "Read the unseal key from the Keychain"
KEY="$(security find-generic-password -s "$KEYCHAIN_ITEM" -w 2>/dev/null || true)"
[ -n "$KEY" ] || die "Keychain item '$KEYCHAIN_ITEM' not found. Vault is unrecoverable without it — check pet-secrets doctor."
printf 'key found (%s bytes)\n' "${#KEY}"

step "Install the watcher on pete-pi-1"
# umask BEFORE the temp file exists, so the extra-vars never sit world-readable.
# mktemp -d gives a 0700 parent, but the file inside it inherits the process umask.
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# JSON, not YAML: a key with a leading quote, a colon or a backslash is a valid
# base64 unseal key and an invalid bare YAML scalar.
python3 -c 'import json,sys;json.dump({"vault_unseal_key":sys.stdin.read().strip()},open(sys.argv[1],"w"))' \
  "$TMP/extra.json" <<<"$KEY"

cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-vault-unseal.yml -e "@$TMP/extra.json" "$@"

step "Done"
echo "The timer runs every five minutes. Check it with:"
echo "  ssh pedro@192.168.50.4 'systemctl list-timers vault-unseal.timer; tail /var/log/vault-unseal.log'"
