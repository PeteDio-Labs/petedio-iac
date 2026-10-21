#!/usr/bin/env bash
# deploy-lab-watchdog.sh — resolve the Discord webhook from Vault and run
# configure-lab-watchdog.yml against claude-247 (PET-707). Modeled on deploy-codex-248.sh.
#
#   kv/services/lab-watchdog -> discord_webhook_url
#     Seeded by seed-lab-watchdog-webhook.sh.
#
# An absent webhook is a hard stop here: a probe that cannot post is a green unit over work
# that never happened. (A bare `ansible-playbook` run still installs the probe and leaves
# the timer off.)
#
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# The webhook reaches jq through its environment, never argv, because `ps` reads argv. The
# extra-vars file lives in a 0700 temp directory and is deleted on exit.
#
#   ./scripts/deploy-lab-watchdog.sh [extra ansible-playbook args, such as --check --diff]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault jq ansible-playbook; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

step "Reading the webhook from Vault (ansible AppRole)"
AN_TOKEN="$(vault write -field=token auth/approle/login \
  role_id="$(cat "$SECRETS/ansible.role_id")" secret_id="$(cat "$SECRETS/ansible.secret_id")" 2>/dev/null)" \
  || die "AppRole login failed for 'ansible'. Run ./scripts/pet-secrets doctor to see whether Vault is sealed."
LAB_WATCHDOG_WEBHOOK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=discord_webhook_url kv/services/lab-watchdog 2>/dev/null || true)"
unset AN_TOKEN
[ -n "$LAB_WATCHDOG_WEBHOOK" ] \
  || die "kv/services/lab-watchdog has no discord_webhook_url. Run ./scripts/seed-lab-watchdog-webhook.sh first."
case "$LAB_WATCHDOG_WEBHOOK" in
  https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) echo "  webhook: present" ;;
  *) die "kv/services/lab-watchdog holds a value that is not a Discord webhook URL." ;;
esac
export LAB_WATCHDOG_WEBHOOK

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
jq -n '{lab_watchdog_discord_webhook_url: env.LAB_WATCHDOG_WEBHOOK}' > "$TMP/extra.json"
unset LAB_WATCHDOG_WEBHOOK

step "Running configure-lab-watchdog.yml"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-lab-watchdog.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  Prove the path from 247 (posts one line to the channel):
    ssh -i ~/.ssh/id_ed25519_pedro claude@192.168.50.247 'sudo lab-watchdog --check'
    ssh -i ~/.ssh/id_ed25519_pedro claude@192.168.50.247 'sudo lab-watchdog --test'
  Prove a DOWN post: stop nothing in production. Point one target at a closed port with
  `-e '{"lab_watchdog_targets":[{"name":"canary","url":"http://127.0.0.1:9/","ok":"200"}]}'`,
  run two cycles, expect one DOWN line, then redeploy without the override.
TXT
