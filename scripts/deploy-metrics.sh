#!/usr/bin/env bash
# deploy-metrics.sh — read the Discord bot fields from Vault and run configure-metrics.yml
# against metrics-240 (PET-708). Modeled on deploy-lab-watchdog.sh.
#
#   kv/services/lab-watchdog -> discord_bot_token, discord_dm_channel_id
#     Seeded by seed-watchdog-discord.sh (PET-728).
#
# The play installs Prometheus, Grafana and the alert evaluator. Without the Discord fields the
# play still runs and leaves the alert timer off, so this script stops when they are absent: an
# evaluator that cannot post is a green unit over work that never happened.
#
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# The token reaches jq through its environment, never argv, because `ps` reads argv. The
# extra-vars file lives in a 0700 temp directory and is deleted on exit.
#
#   ./scripts/deploy-metrics.sh [extra ansible-playbook args, such as --check --diff]
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

step "Reading the Discord bot fields from Vault (ansible AppRole)"
AN_TOKEN="$(vault write -field=token auth/approle/login \
  role_id=@"$SECRETS/ansible.role_id" secret_id=@"$SECRETS/ansible.secret_id" 2>/dev/null)" \
  || die "AppRole login failed for 'ansible'. Run ./scripts/pet-secrets doctor to see whether Vault is sealed."
# Only "No value found" means the record is absent. Any other error stops the script.
RECORD="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -format=json kv/services/lab-watchdog 2>&1)" || {
  case "$RECORD" in
    *"No value found"*) RECORD='{}' ;;
    *) unset AN_TOKEN; die "reading kv/services/lab-watchdog failed. Run ./scripts/pet-secrets doctor." ;;
  esac
}
unset AN_TOKEN
METRICS_DISCORD_BOT_TOKEN="$(printf '%s' "$RECORD" | jq -r '.data.data.discord_bot_token // empty')"
METRICS_DISCORD_DM_CHANNEL_ID="$(printf '%s' "$RECORD" | jq -r '.data.data.discord_dm_channel_id // empty')"
unset RECORD
[ -n "$METRICS_DISCORD_BOT_TOKEN" ] && [ -n "$METRICS_DISCORD_DM_CHANNEL_ID" ] \
  || die "kv/services/lab-watchdog lacks the Discord bot fields. Run ./scripts/seed-watchdog-discord.sh first."
echo "  discord bot token and DM channel: present"
export METRICS_DISCORD_BOT_TOKEN METRICS_DISCORD_DM_CHANNEL_ID

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
jq -n '{metric_alerts_discord_bot_token: env.METRICS_DISCORD_BOT_TOKEN,
  metric_alerts_discord_dm_channel_id: env.METRICS_DISCORD_DM_CHANNEL_ID}' > "$TMP/extra.json"
unset METRICS_DISCORD_BOT_TOKEN

step "Running configure-metrics.yml"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/metrics.yml playbooks/configure-metrics.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  Prove the alert path (posts one line to the Lab-Agent DM):
    ssh root@192.168.50.240 'metric-alerts --test'
  Open the dashboard: http://192.168.50.240:3000/d/lab-overview
  The admin password is in /etc/grafana/admin-password on metrics-240 (root only).
TXT
