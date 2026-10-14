#!/usr/bin/env bash
# seed-backup-health-vault.sh — mint one Uptime Kuma push token per Proxmox node and
# store them at kv/services/backup-health (PET-529).
#
# Each node's daily backup-health check pushes its verdict to a Kuma push monitor.
# The push URL is the token, so anyone holding it can report a node healthy. Both
# consumers read it from here with the ansible AppRole:
#   scripts/deploy-uptime-kuma.sh     declares the monitors backups-<node>
#   scripts/deploy-backup-store.sh    writes /etc/backup-health.env on each node
#
# WHY A SCRIPT AND NOT TERRAFORM. A vault_kv_secret_v2 resource would write the tokens
# in plaintext into the MinIO-backed state. Writing kv/services/* also needs a
# privileged token that the AppRoles do not hold.
#
# The Vault token comes from $VAULT_TOKEN, else the Keychain item vault-root-token.
# It never prompts. Existing tokens are kept, so a re-run changes nothing, unless you
# pass --rotate. After a rotation, run both deploy scripts, or every push is refused.
#
#   ./scripts/seed-backup-health-vault.sh            # mint any token that is missing
#   ./scripts/seed-backup-health-vault.sh --rotate   # replace every token
set -euo pipefail

ROTATE=0
for arg in "${@:-}"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    ""|--) : ;;
    -h|--help) printf 'usage: %s [--rotate]\n' "${0##*/}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/backup-health"
NODES=(pve02 pve03)

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

command -v vault >/dev/null || die "vault not in PATH."
command -v python3 >/dev/null || die "python3 not in PATH."

step "Credentials"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s vault-root-token -a vault-223 -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] \
  || die "no VAULT_TOKEN and no Keychain item (service vault-root-token, account vault-223)."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid, or Vault is sealed or unreachable."
echo "  vault reachable and token valid"

step "Tokens"
EXISTING="$(vault kv get -format=json "$PATH_KV" 2>/dev/null || true)"
# Build the full secret in Python and hand it to vault on stdin, so no token ever
# appears in argv, where `ps` shows it to every user.
NEW_JSON="$(printf '%s' "$EXISTING" | ROTATE=$ROTATE python3 -c '
import json, os, secrets, string, sys
try:
    have = json.load(sys.stdin)["data"]["data"]
except Exception:
    have = {}
alphabet = string.ascii_letters + string.digits
out, report = {}, []
for node in sys.argv[1:]:
    if have.get(node) and os.environ["ROTATE"] != "1":
        out[node] = have[node]
        report.append(f"{node}: kept")
    else:
        out[node] = "".join(secrets.choice(alphabet) for _ in range(32))
        report.append(f"{node}: minted")
print(json.dumps({"data": out, "report": report}))
' "${NODES[@]}")"
printf '%s' "$NEW_JSON" | python3 -c 'import json,sys; [print("  " + r) for r in json.load(sys.stdin)["report"]]'
printf '%s' "$NEW_JSON" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"]))' \
  | vault kv put "$PATH_KV" - >/dev/null || die "could not write $PATH_KV"

step "Read back"
# Count what Vault returns, not what this script sent.
BACK="$(vault kv get -format=json "$PATH_KV")" || die "could not read $PATH_KV back"
printf '%s' "$BACK" | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]["data"]
bad = [n for n in sys.argv[1:] if len(d.get(n) or "") < 16]
for n in sys.argv[1:]:
    size = len(d.get(n) or "")
    print(f"  {n}: {size} characters")
sys.exit(1 if bad else 0)
' "${NODES[@]}" || die "a token is missing or short after the write"

step "Next"
cat <<'EOF'
  1. ./scripts/deploy-uptime-kuma.sh     declares backups-pve02 and backups-pve03
  2. ./scripts/deploy-backup-store.sh    gives each node its push URL
  Then run the check once on a node: systemctl start backup-health.service
EOF
