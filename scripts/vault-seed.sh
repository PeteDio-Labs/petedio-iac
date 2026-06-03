#!/usr/bin/env bash
#
# vault-seed.sh — seed bootstrap secret VALUES into the homelab Vault KV-v2 store.
#
# operator-run; requires VAULT_ADDR/VAULT_CACERT/VAULT_TOKEN; no values are committed.
#
# Each value is taken from a matching env var if already exported, otherwise prompted
# for interactively with `read -s` (silent — no terminal echo). Values are held only
# in shell variables and passed to `vault kv put`; this script NEVER echoes a value,
# NEVER writes one to disk, and NEVER logs one. Idempotent: re-running overwrites the
# same KV entries with the same (re-entered) values — safe to repeat.
#
# Source of each value → docs/runbooks/vault-seed.md (Source mapping). Real values come
# from the old homelab-infra ansible-vault files or Pedro's password manager.
#
# Usage:
#   export VAULT_ADDR="https://192.168.50.223:8200"
#   export VAULT_CACERT="$(pwd)/environments/homelab/vault-ca.crt"
#   vault login            # or: export VAULT_TOKEN=<root/bootstrap token>
#   ./scripts/vault-seed.sh
#
# Optional pre-set env vars (skip the prompt for that value):
#   PROXMOX_API_TOKEN
#   MINIO_ACCESS_KEY  MINIO_SECRET_KEY
#   LXC_SSH_PUBLIC_KEY  LXC_SSH_PRIVATE_KEY   (private key = full PEM contents)
#   POSTGRES_ADMIN_PASSWORD  POKER_PASSWORD
#   QBT_USERNAME  QBT_PASSWORD
#   AUTHENTIK_SECRET_KEY  AUTHENTIK_BOOTSTRAP_TOKEN
#   CLOUDFLARE_TUNNEL_TOKEN
#   NEXUS_ADMIN_PASSWORD
#
set -euo pipefail

# --- preflight -------------------------------------------------------------------
: "${VAULT_ADDR:?set VAULT_ADDR (e.g. https://192.168.50.223:8200)}"
: "${VAULT_CACERT:?set VAULT_CACERT to the path of environments/homelab/vault-ca.crt}"
: "${VAULT_TOKEN:?run 'vault login' or export VAULT_TOKEN (root/bootstrap token)}"

command -v vault >/dev/null 2>&1 || { echo "FATAL: vault CLI not found on PATH" >&2; exit 1; }

# Fail fast if Vault is unreachable or sealed (don't half-seed).
if ! vault status >/dev/null 2>&1; then
  echo "FATAL: 'vault status' failed — Vault unreachable or sealed. Check VAULT_ADDR/CACERT and unseal." >&2
  exit 1
fi

# --- helper: load a value from env var $1, else prompt silently --------------------
# Sets global REPLY_VALUE. Never echoes the value. Rejects empty input.
load_value() {
  local var_name="$1" prompt="$2" existing
  existing="${!var_name-}"
  if [ -n "$existing" ]; then
    REPLY_VALUE="$existing"
    echo "  $var_name: using exported env var"
    return 0
  fi
  local v=""
  while [ -z "$v" ]; do
    # -s: silent (no echo); prompt to stderr so it shows even if stdout is piped.
    read -r -s -p "  $prompt: " v < /dev/tty
    echo >&2   # newline after the silent prompt
    [ -z "$v" ] && echo "  (empty — please re-enter)" >&2
  done
  REPLY_VALUE="$v"
}

# --- helper: put one KV entry. Args: <path> then key=valuevar pairs are built by ---
# the callers below. We build the `vault kv put` arg array WITHOUT ever expanding a
# value into a command echoed by `set -x`-style tracing (this script never sets -x).
put_entry() {
  local path="$1"; shift
  # remaining args are literal key=value strings already assembled by the caller
  if vault kv put "$path" "$@" >/dev/null; then
    echo "  -> wrote $path"
  else
    echo "FATAL: failed to write $path" >&2
    exit 1
  fi
}

echo "Seeding Vault KV at ${VAULT_ADDR} ..."
echo "(values are read from env or prompted silently; nothing is echoed or written to disk)"
echo

# --- kv/iac/proxmox --------------------------------------------------------------
echo "kv/iac/proxmox:"
load_value PROXMOX_API_TOKEN "Proxmox API token (homelab-infra terraform.vault.yml)"
put_entry kv/iac/proxmox "api_token=${REPLY_VALUE}"
echo

# --- kv/iac/minio ----------------------------------------------------------------
echo "kv/iac/minio:"
load_value MINIO_ACCESS_KEY "MinIO access_key (homelab-infra minio-terraform-state.vault.yml)"
minio_access="${REPLY_VALUE}"
load_value MINIO_SECRET_KEY "MinIO secret_key"
put_entry kv/iac/minio "access_key=${minio_access}" "secret_key=${REPLY_VALUE}"
unset minio_access
echo

# --- kv/iac/lxc-ssh --------------------------------------------------------------
# Private key is multi-line PEM. If LXC_SSH_PRIVATE_KEY is exported, use it directly.
# Otherwise prompt for a FILE PATH (a multi-line secret can't be read via `read -s`),
# read it, then shred the file is the operator's responsibility — we never create it.
echo "kv/iac/lxc-ssh:"
load_value LXC_SSH_PUBLIC_KEY "LXC SSH public_key (single line, homelab-infra)"
lxc_pub="${REPLY_VALUE}"
if [ -n "${LXC_SSH_PRIVATE_KEY-}" ]; then
  echo "  LXC_SSH_PRIVATE_KEY: using exported env var"
  put_entry kv/iac/lxc-ssh "public_key=${lxc_pub}" "private_key=${LXC_SSH_PRIVATE_KEY}"
else
  key_path=""
  while [ -z "$key_path" ] || [ ! -r "$key_path" ]; do
    read -r -p "  Path to LXC SSH private key file (PEM; will NOT be modified): " key_path < /dev/tty
    [ -r "$key_path" ] || echo "  (file not readable — re-enter)" >&2
  done
  # @file makes vault read the value from the file directly.
  put_entry kv/iac/lxc-ssh "public_key=${lxc_pub}" "private_key=@${key_path}"
  echo "  NOTE: remember to 'shred -u ${key_path}' if it is a temporary copy." >&2
fi
unset lxc_pub
echo

# --- kv/poker/db -----------------------------------------------------------------
# DATABASE_URL is derived from POKER_PASSWORD. admin_password + poker_password were set
# at the manual Postgres standup (password manager) — NOT in homelab-infra.
echo "kv/poker/db:"
load_value POSTGRES_ADMIN_PASSWORD "Postgres ADMIN/superuser password (password manager)"
pg_admin="${REPLY_VALUE}"
load_value POKER_PASSWORD "Postgres 'poker' role password (password manager; must match TF_VAR_poker_db_password)"
poker_pw="${REPLY_VALUE}"
database_url="postgresql://poker:${poker_pw}@192.168.50.231:5432/poker?sslmode=disable"
put_entry kv/poker/db \
  "DATABASE_URL=${database_url}" \
  "admin_password=${pg_admin}" \
  "poker_password=${poker_pw}"
unset pg_admin poker_pw database_url
echo

# --- kv/services/qbittorrent -----------------------------------------------------
echo "kv/services/qbittorrent:"
load_value QBT_USERNAME "qBittorrent username (homelab-infra qbittorrent.vault.yml)"
qbt_user="${REPLY_VALUE}"
load_value QBT_PASSWORD "qBittorrent password"
put_entry kv/services/qbittorrent "username=${qbt_user}" "password=${REPLY_VALUE}"
unset qbt_user
echo

# --- kv/services/authentik -------------------------------------------------------
echo "kv/services/authentik:"
load_value AUTHENTIK_SECRET_KEY "Authentik secret_key (homelab-infra)"
ak_secret="${REPLY_VALUE}"
load_value AUTHENTIK_BOOTSTRAP_TOKEN "Authentik bootstrap_token"
put_entry kv/services/authentik "secret_key=${ak_secret}" "bootstrap_token=${REPLY_VALUE}"
unset ak_secret
echo

# --- kv/services/cloudflare ------------------------------------------------------
echo "kv/services/cloudflare:"
load_value CLOUDFLARE_TUNNEL_TOKEN "Cloudflare tunnel_token (homelab-infra)"
put_entry kv/services/cloudflare "tunnel_token=${REPLY_VALUE}"
echo

# --- kv/services/nexus -----------------------------------------------------------
echo "kv/services/nexus:"
load_value NEXUS_ADMIN_PASSWORD "Nexus admin_password (homelab-infra or password manager)"
put_entry kv/services/nexus "admin_password=${REPLY_VALUE}"
echo

# scrub the last-used value holder
unset REPLY_VALUE

echo "Done. All KV entries written."
echo "Next: provision AppRole creds (see docs/runbooks/vault-seed.md) and run scripts/vault-verify.sh"
