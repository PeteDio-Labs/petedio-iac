#!/usr/bin/env bash
# reseed-media-dash-vault.sh — (re)seed kv/services/media/dashboard with the ONLY two
# credentials mtrace needs: a dedicated SSH keypair for reading the media hosts, and the
# bearer token for its own HTTP API (PET-355).
#
# ⚠ WHAT IS DELIBERATELY NOT HERE: the Sonarr, Radarr, Prowlarr, seerr and Plex API keys.
# PET-355 budgeted for holding all seven centrally and called it "the actual cost of this
# phase". The transport that shipped does not need them — the curl runs ON each host, so a
# key is read from that host's own config, used on its own loopback, and only the RESPONSE
# crosses the LAN. Pulling them into Vault would have SPENT that budget on a regression.
#
# ⚠ And it could never have been complete. qBittorrent's WebUI is unreachable from off-box
# whatever credential you hold: Docker SNATs host-origin traffic to the bridge gateway,
# outside `WebUI\AuthSubnetWhitelistEnabled`, so the only route in is `docker exec` inside
# the netns — over SSH. A Vault-held-keys design would still have needed this SSH key.
#
# ⚠ WHY A DEDICATED KEYPAIR AND NOT kv/iac/lxc-ssh: that key is root on every container in
# the lab. media-dash-237 runs a read-only diagnostic reachable over HTTP; it must not hold
# the lab's master key. The public half is installed on exactly six hosts by
# playbooks/configure-media-dash.yml, and nowhere else.
#
# Idempotent: existing material is left alone. Pass --rotate to mint fresh material, which
# then REQUIRES re-running scripts/deploy-media-dash.sh to push the new public key out —
# rotating without deploying leaves 237 holding a key nothing accepts.
#
# No secrets printed. Vault token: $VAULT_TOKEN, else macOS Keychain $VAULT_TOKEN_KEYCHAIN_ITEM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
SECRET_PATH="kv/services/media/dashboard"
ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ssh-keygen python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Checking what is already at $SECRET_PATH"
EXISTING="$(vault kv get -format=json "$SECRET_PATH" 2>/dev/null || echo '{}')"
HAS_KEY="$(printf '%s' "$EXISTING" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)["data"]["data"]
except Exception: d={}
print("1" if d.get("ssh_private_key") and d.get("ssh_public_key") else "0")')"
HAS_TOKEN="$(printf '%s' "$EXISTING" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)["data"]["data"]
except Exception: d={}
print("1" if d.get("api_token") else "0")')"

if [ "$HAS_KEY" = "1" ] && [ "$HAS_TOKEN" = "1" ] && [ "$ROTATE" = "0" ]; then
  echo "  Already seeded (keypair + api_token present). Nothing to do."
  echo "  Pass --rotate to mint fresh material, then re-run scripts/deploy-media-dash.sh."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "Minting material"
if [ "$HAS_KEY" = "0" ] || [ "$ROTATE" = "1" ]; then
  # ed25519 to match the rest of the lab. No passphrase: a systemd service cannot type one,
  # and the protection here is the key's SCOPE (six hosts) plus its 0600 file mode.
  ssh-keygen -t ed25519 -N '' -C "mtrace@media-dash-237 (PET-355)" -f "$TMP/id_ed25519_mtrace" >/dev/null
  NEW_PRIV="$(cat "$TMP/id_ed25519_mtrace")"
  NEW_PUB="$(cat "$TMP/id_ed25519_mtrace.pub")"
  echo "  minted a fresh ed25519 keypair"
else
  NEW_PRIV="$(printf '%s' "$EXISTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["data"]["ssh_private_key"])')"
  NEW_PUB="$(printf '%s' "$EXISTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["data"]["ssh_public_key"])')"
  echo "  kept the existing keypair"
fi

if [ "$HAS_TOKEN" = "0" ] || [ "$ROTATE" = "1" ]; then
  NEW_TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  echo "  minted a fresh api_token"
else
  NEW_TOKEN="$(printf '%s' "$EXISTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["data"]["api_token"])')"
  echo "  kept the existing api_token"
fi

step "Writing $SECRET_PATH"
# Written from a FILE, never as argv: `vault kv put k=v` puts the secret in this process's
# command line, where `ps` can read it. The values reach python through the ENVIRONMENT for
# the same reason - argv is world-readable on a shared box, an environ is not.
MTRACE_PRIV="$NEW_PRIV" MTRACE_PUB="$NEW_PUB" MTRACE_TOKEN="$NEW_TOKEN" \
python3 -c '
import json, os, sys
json.dump({
    "ssh_private_key": os.environ["MTRACE_PRIV"],
    "ssh_public_key": os.environ["MTRACE_PUB"].strip(),
    "api_token": os.environ["MTRACE_TOKEN"],
}, open(sys.argv[1], "w"))
' "$TMP/payload.json"
vault kv put "$SECRET_PATH" @"$TMP/payload.json" >/dev/null
echo "  wrote ssh_private_key, ssh_public_key, api_token"

step "Done"
cat <<MSG
  $SECRET_PATH now holds the three fields configure-media-dash.yml expects.

  Readable by: the media-dash-cd JWT role (the repo's deploy.yml) and the ansible policy.
  Explicitly DENIED to media-ci. That role reads kv/services/media/* for the media stack,
  and this path sits under the same prefix while holding something categorically different
  — an SSH key that is root on six media containers. vault-config's media-ci policy carries
  an exact-path deny for it; without that, seeding here would have quietly promoted
  petedio-media-iac's CI from reading the stack's secrets to controlling the stack.

  Next: ./scripts/deploy-media-dash.sh
MSG
