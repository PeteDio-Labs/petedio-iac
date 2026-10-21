#!/usr/bin/env bash
# deploy-lab-watchdog.sh — resolve the Discord bot credentials from Vault and run
# configure-lab-watchdog.yml against claude-247 (PET-707). Modeled on deploy-codex-248.sh.
#
#   kv/services/lab-watchdog -> discord_bot_token, discord_dm_channel_id
#     Seeded by seed-watchdog-discord.sh.
#
# Absent credentials are a hard stop here: a probe that cannot post is a green unit over work
# that never happened. (A bare `ansible-playbook` run still installs the probe and leaves
# the timer off.)
#
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# The token reaches jq through its environment, never argv, because `ps` reads argv. The
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

step "Reading the Discord credentials from Vault (ansible AppRole)"
# `key=@file` makes the Vault CLI read the value from the file, so neither the RoleID nor the
# SecretID reaches argv, where `ps` would show them.
AN_TOKEN="$(vault write -field=token auth/approle/login \
  role_id=@"$SECRETS/ansible.role_id" secret_id=@"$SECRETS/ansible.secret_id" 2>/dev/null)" \
  || die "AppRole login failed for 'ansible'. Run ./scripts/pet-secrets doctor to see whether Vault is sealed."
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# read_record PATH -> prints the record as JSON. A path with no record prints {}, so "absent"
# is reported as absent. Any other failure (a denied read, a sealed Vault) stops the deploy,
# because an unread record must not read as an unseeded one.
read_record() {
  local out
  if out="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -format=json "$1" 2>"$TMP/err")"; then
    printf '%s' "$out" | jq -c '.data.data'
  elif grep -q 'No value found' "$TMP/err"; then
    echo '{}'
  else
    die "could not read $1: $(head -c 300 "$TMP/err")"
  fi
}
field() { printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty'; }

LAB_REC="$(read_record kv/services/lab-watchdog)"
# The off-site heartbeat (PET-722) is optional: absent, the in-lab probe still runs.
AWS_REC="$(read_record kv/services/aws-watchdog)"
unset AN_TOKEN
DISCORD_BOT_TOKEN="$(field "$LAB_REC" discord_bot_token)"
DISCORD_DM_CHANNEL_ID="$(field "$LAB_REC" discord_dm_channel_id)"
HB_URL="$(field "$AWS_REC" heartbeat_url)"
HB_SECRET="$(field "$AWS_REC" heartbeat_secret)"
unset LAB_REC AWS_REC
[ -n "$DISCORD_BOT_TOKEN" ] && [ -n "$DISCORD_DM_CHANNEL_ID" ] \
  || die "kv/services/lab-watchdog has no discord_bot_token or discord_dm_channel_id. Run ./scripts/seed-watchdog-discord.sh first."
case "$DISCORD_DM_CHANNEL_ID" in
  *[!0-9]*) die "kv/services/lab-watchdog holds a discord_dm_channel_id that is not a number." ;;
  *) echo "  Discord bot token and DM channel: present" ;;
esac
if [ -n "$HB_URL" ] && [ -n "$HB_SECRET" ]; then
  echo "  off-site heartbeat: present"
else
  echo "  off-site heartbeat: not seeded (PET-722), the play leaves the file as it is"
fi
export DISCORD_BOT_TOKEN DISCORD_DM_CHANNEL_ID HB_URL HB_SECRET

jq -n '{lab_watchdog_discord_bot_token: env.DISCORD_BOT_TOKEN,
  lab_watchdog_discord_dm_channel_id: env.DISCORD_DM_CHANNEL_ID,
  lab_watchdog_heartbeat_url: env.HB_URL, lab_watchdog_heartbeat_secret: env.HB_SECRET}' > "$TMP/extra.json"
unset DISCORD_BOT_TOKEN HB_SECRET

step "Running configure-lab-watchdog.yml"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-lab-watchdog.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  Prove the path from 247 (posts one line to the Lab-Agent DM):
    ssh -i ~/.ssh/id_ed25519_pedro claude@192.168.50.247 'sudo lab-watchdog --check'
    ssh -i ~/.ssh/id_ed25519_pedro claude@192.168.50.247 'sudo lab-watchdog --test'
  Prove a DOWN post: stop nothing in production. Point one target at a closed port with
  `-e '{"lab_watchdog_targets":[{"name":"canary","url":"http://127.0.0.1:9/","ok":"200"}]}'`,
  run two cycles, expect one DOWN line, then redeploy without the override.
TXT
