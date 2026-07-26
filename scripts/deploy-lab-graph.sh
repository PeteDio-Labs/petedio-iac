#!/usr/bin/env bash
# deploy-lab-graph.sh — build/push/deploy the lab-graph function to faasd on LXC 241.
#
# WHY THIS SHAPE (differs from deploy-admin.sh, deliberately):
#
#   1. It builds on runner-232, not on the Mac. The image must be linux/amd64; the Mac is
#      arm64 and its Docker daemon is not always running. runner-232 is native amd64, already
#      has Docker + buildx, and is inside the LAN. No cross-build, no QEMU emulation.
#
#   2. It deploys from ON 241 over loopback. The faasd gateway is firewalled to source
#      192.168.50.230 only (PET-204/F1), so `faas-cli` cannot reach :8080 from the Mac at all.
#      Running it on the box sidesteps the gate rather than punching a hole in it.
#
#   3. The PVE token goes in as a faasd SECRET, not an environment variable. It lands at
#      /var/openfaas/secrets/pve-ro-token inside the container and never appears in the image,
#      the stack file, the unit, or `faas-cli describe` output.
#
# The token is a PVEAuditor (read-only) token — lab-graph only ever issues GETs.
#
# Prereqs: vault + ssh on PATH; the Keychain root token (see Systems/vault-and-secrets in the
# vault repo — the ansible/terraform-local AppRoles are read-only for kv/services/*).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="${BUILDER_HOST:-192.168.50.232}"   # runner-232 — amd64, has Docker
FAASD="${FAASD_HOST:-192.168.50.241}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
IMAGE="docker.pdlab.dev/lab-graph:latest"
REMOTE_SRC="/tmp/lab-graph-build"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$ROOT/environments/homelab/vault-ca.crt}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

for t in vault ssh scp; do command -v "$t" >/dev/null || die "$t not in PATH"; done

SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 -i $SSH_KEY"

# ---- credentials -------------------------------------------------------------------------
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s vault-root-token -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp 'Vault token: ' VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die 'Vault unreachable / token invalid.'

PVE_RO="$(vault kv get -field=proxmox_ro_token kv/services/agent-loop)"
NEXUS_U="$(vault kv get -field=username kv/services/nexus 2>/dev/null || echo admin)"
NEXUS_P="$(vault kv get -field=admin_password kv/services/nexus)"
GW_PW="$(vault kv get -field=gateway_password kv/services/openfaas)"

# ---- 1. build + push on runner-232 -------------------------------------------------------
say "Building $IMAGE on $BUILDER (native amd64)"
$SSH "root@$BUILDER" "rm -rf $REMOTE_SRC && mkdir -p $REMOTE_SRC"
scp -q -o BatchMode=yes -i "$SSH_KEY" \
  "$ROOT"/tools/lab-graph/{Dockerfile,package.json,server.ts,layout.json} \
  "root@$BUILDER:$REMOTE_SRC/"

# Creds arrive on stdin, never argv — argv is world-readable in /proc.
printf '%s\n%s\n' "$NEXUS_U" "$NEXUS_P" | $SSH "root@$BUILDER" "
  set -euo pipefail
  read -r u; read -r p
  printf '%s' \"\$p\" | docker login docker.pdlab.dev -u \"\$u\" --password-stdin >/dev/null
  cd $REMOTE_SRC
  docker build -q -t $IMAGE . >/dev/null
  docker push -q $IMAGE >/dev/null
  docker logout docker.pdlab.dev >/dev/null
  rm -rf $REMOTE_SRC
  echo 'built + pushed'
"

# ---- 2. seed the secret + deploy on 241 --------------------------------------------------
say "Deploying on $FAASD (loopback gateway — LAN :8080 is locked to .230)"
printf '%s\n%s\n' "$GW_PW" "$PVE_RO" | $SSH "root@$FAASD" "
  set -euo pipefail
  read -r gw; read -r tok
  printf '%s' \"\$gw\" | faas-cli login --gateway http://127.0.0.1:8080 -u admin --password-stdin >/dev/null

  # faasd has no 'secret update'; remove-then-create is the idempotent path.
  printf '%s' \"\$tok\" | faas-cli secret create pve-ro-token --gateway http://127.0.0.1:8080 --from-file=/dev/stdin >/dev/null 2>&1 \
    || { faas-cli secret remove pve-ro-token --gateway http://127.0.0.1:8080 >/dev/null 2>&1
         printf '%s' \"\$tok\" | faas-cli secret create pve-ro-token --gateway http://127.0.0.1:8080 --from-file=/dev/stdin >/dev/null; }

  faas-cli deploy \
    --gateway http://127.0.0.1:8080 \
    --name lab-graph \
    --image $IMAGE \
    --secret pve-ro-token \
    --env PVE01_URL=https://192.168.50.10:8006 \
    --env PVE02_URL=https://192.168.50.11:8006 \
    --env PVE_TIMEOUT_MS=6000 \
    --label com.openfaas.scale.min=1
"

# ---- 3. verify ---------------------------------------------------------------------------
say "Verifying"
$SSH "root@$FAASD" '
  for i in $(seq 1 20); do
    code=$(curl -s -o /tmp/lg.json -w "%{http_code}" http://127.0.0.1:8080/function/lab-graph || true)
    [ "$code" = "200" ] && break
    sleep 3
  done
  echo "HTTP $code"
  [ "$code" = "200" ] || { echo "--- body ---"; head -c 400 /tmp/lg.json; exit 1; }
  python3 -c "
import json
d=json.load(open(\"/tmp/lg.json\"))
print(\"sources :\", d[\"sources\"])
print(\"counts  :\", d[\"counts\"])
print(\"warnings:\", len(d[\"warnings\"]))
for w in d[\"warnings\"]: print(\"  [\"+w[\"code\"]+\"]\", w[\"detail\"])
"
  rm -f /tmp/lg.json
'

say "Done. Invoke from .230 (or on-box) at http://192.168.50.241:8080/function/lab-graph"
