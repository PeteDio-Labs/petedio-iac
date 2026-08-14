#!/usr/bin/env bash
# plane-finish.sh — everything after the three human steps of PET-287.
#
# Paste the Plane personal access token when prompted. It is never echoed, never in
# argv, and never in shell history. This script then:
#
#   1. stores it in Vault with `kv patch` (never `put`) and PROVES the other fields survived
#   2. runs plane-bootstrap.sh (creates the PET project, probes sequence_id, adds "In Review")
#   3. sets the three PLANE_* variables on all nine repos bound to the plane-ci role
#   4. reads every variable back and reports what actually landed
#
#   ./scripts/plane-finish.sh
#
# Idempotent: safe to re-run. Re-running re-patches the same token, finds the existing
# project, and overwrites the repo variables with the same values.
#
# Requires: vault, gh (authenticated), python3, curl, and the Mac keychain entry
# `vault-root-token`. Tailscale must be up — Plane and Vault are tailnet-only.

set -uo pipefail

BASE="${PLANE_BASE_URL:-http://192.168.50.235:8080}"
IAC="${IAC_DIR:-$HOME/petedio/iac}"
VAULT_SECRET="kv/services/plane"

# The nine repos bound to the plane-ci JWT role. Canonical source is
# environments/homelab/vault-config/variables.tf -> var.plane_repos.
# NB: this list includes petedio-water-fast and excludes petedio-workspace, which is the
# opposite of the table in .claude/CLAUDE.md. The Terraform list is the one that matters —
# it is what Vault actually binds.
REPOS=(
  PeteDio-Labs/petedio-iac
  PeteDio-Labs/petedio-media-iac
  PeteDio-Labs/co-latro-backend
  PeteDio-Labs/co-latro-frontend
  PeteDio-Labs/co-latro-admin
  PeteDio-Labs/petedio-resume-builder
  PeteDio-Labs/petedio-palworld-panel
  PeteDio-Labs/petedio-water-fast
  PeteDio-Labs/petedio-vault
)

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){   printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m⚠\033[0m %s\n' "$*"; }
die(){  printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------------
for bin in vault gh python3 curl security; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is not on PATH."
done
[ -d "$IAC" ] || die "iac clone not found at $IAC (override with IAC_DIR=...)."
[ -x "$IAC/scripts/plane-bootstrap.sh" ] || die "$IAC/scripts/plane-bootstrap.sh is missing or not executable."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
ok "tools, iac clone, gh auth"

curl -sS --max-time 8 -o /dev/null "$BASE/" \
  || die "Plane at $BASE is unreachable. Is Tailscale up?"
ok "Plane reachable at $BASE"

# ---------------------------------------------------------------------------------
step "Personal access token"
# ---------------------------------------------------------------------------------
printf '  Paste the PAT (input hidden), then press Return: '
read -rs PAT
printf '\n'
[ -n "$PAT" ] || die "no token entered."

# Prove the token works before we store it anywhere. A token that does not authenticate
# is one that will fail silently in CI three days from now.
#
# The slug is an INPUT, not something to discover. Plane's public API has no
# list-workspaces endpoint — every route is scoped under /workspaces/<slug>/, as
# plane-sync.sh:50 has always done. An earlier version of this script called
# GET /api/v1/workspaces/, got nothing back because the route does not exist, and
# reported it as a bad token.
WS="${PLANE_WORKSPACE:-petedio}"

# Checks the HTTP status, not the body: before bootstrap runs, an EMPTY project list is
# the correct answer, so "no results" must not be read as failure.
CODE=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
  -H "X-API-Key: $PAT" "$BASE/api/v1/workspaces/$WS/projects/" 2>/dev/null)
case "$CODE" in
  200)     ok "token authenticates against workspace '$WS'" ;;
  401|403) die "the token was rejected (HTTP $CODE). Recreate it at $BASE/settings/profile/api-tokens/ and re-run." ;;
  404)     die "workspace '$WS' not found (HTTP 404). Re-run with PLANE_WORKSPACE=<your-slug> $0" ;;
  000)     die "no response from $BASE. Is Tailscale up?" ;;
  *)       die "unexpected HTTP $CODE from $BASE/api/v1/workspaces/$WS/projects/" ;;
esac

# ---------------------------------------------------------------------------------
step "Store it in Vault (patch, never put)"
# ---------------------------------------------------------------------------------
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$IAC/environments/homelab/vault-ca.crt}"
[ -f "$VAULT_CACERT" ] || die "Vault CA cert not found at $VAULT_CACERT"
VAULT_TOKEN="$(security find-generic-password -s vault-root-token -w 2>/dev/null)" \
  || die "could not read vault-root-token from the keychain."
export VAULT_TOKEN

vault status >/dev/null 2>&1 || die "Vault at $VAULT_ADDR is unreachable or sealed. Try: pet-secrets doctor"
ok "Vault reachable and unsealed"

# Snapshot the field names BEFORE, so we can prove nothing was clobbered.
BEFORE=$(vault kv get -format=json "$VAULT_SECRET" 2>/dev/null | python3 -c "
import sys,json
try: print(' '.join(sorted(json.load(sys.stdin)['data']['data'].keys())))
except Exception: pass")
[ -n "$BEFORE" ] || die "could not read $VAULT_SECRET. Refusing to write blind."
echo "  existing fields: $BEFORE"

# `api_key=-` makes the Vault CLI read the value from stdin, so the token never appears
# in argv (where a stray `ps`/`pgrep` would print it — the exact leak that forced the
# rotation behind open item #1 of the handoff).
printf '%s' "$PAT" | vault kv patch "$VAULT_SECRET" api_key=- >/dev/null 2>&1 \
  || die "vault kv patch failed. Nothing was written."

# Verify, do not assume. Two ways this silently goes wrong: the `-` stdin convention is
# not honoured (it is stored literally, cf. the `vault operator unseal -` lesson), or a
# `put`-shaped write wiped the siblings.
AFTER=$(vault kv get -format=json "$VAULT_SECRET" 2>/dev/null | python3 -c "
import sys,json
try: print(' '.join(sorted(json.load(sys.stdin)['data']['data'].keys())))
except Exception: pass")
STORED=$(vault kv get -field=api_key "$VAULT_SECRET" 2>/dev/null)

[ "$STORED" = "$PAT" ] || die "the stored api_key does not match what you pasted (got ${#STORED} chars, expected ${#PAT}). Fix by hand before deploying."
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "field '$f' disappeared from $VAULT_SECRET. This is the clobber the handoff warns about — restore from a previous version: vault kv rollback -version=<n> $VAULT_SECRET";; esac
done
ok "api_key stored and verified byte-for-byte"
ok "all prior fields intact: $AFTER"

# ---------------------------------------------------------------------------------
step "Bootstrap the PET project"
# ---------------------------------------------------------------------------------
# plane-bootstrap.sh takes the key via the environment, not argv. Same-user `ps -E` can
# still read it for the few seconds it runs; that is the sibling script's interface, not
# something this wrapper can fix without changing it.
export PLANE_API_KEY="$PAT"
export PLANE_WORKSPACE="$WS"
export PLANE_BASE_URL="$BASE"
( cd "$IAC" && ./scripts/plane-bootstrap.sh )
BOOT_RC=$?
unset PLANE_API_KEY
[ $BOOT_RC -eq 0 ] || die "plane-bootstrap.sh exited $BOOT_RC. Read its output above; nothing below has run."

# ---------------------------------------------------------------------------------
step "Resolve the PET project id"
# ---------------------------------------------------------------------------------
# Queried fresh rather than scraped from the bootstrap output, so a change to its
# print format cannot silently feed a blank id into nine repos.
PID=$(curl -sS --max-time 15 -H "X-API-Key: $PAT" "$BASE/api/v1/workspaces/$WS/projects/" 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d.get('results', d if isinstance(d,list) else []):
    if str(p.get('identifier','')).upper()=='PET': print(p['id']); break")
[ -n "$PID" ] || die "no project with identifier PET found in workspace '$WS'."
ok "PET project: $PID"

# ---------------------------------------------------------------------------------
step "Repo variables"
# ---------------------------------------------------------------------------------
cat <<EOF
  PLANE_BASE_URL   = $BASE
  PLANE_WORKSPACE  = $WS
  PLANE_PROJECT_ID = $PID

  About to set these on ${#REPOS[@]} repos (${#REPOS[@]} x 3 = $(( ${#REPOS[@]} * 3 )) variables).
EOF
printf '  Continue? [y/N] '
read -r REPLY
case "$REPLY" in [yY]*) ;; *) die "stopped before touching any repo. Vault and Plane are already done — re-run and answer y to finish.";; esac

# Accumulators are space-separated strings, not arrays: macOS ships bash 3.2, where
# "${arr[@]}" on an EMPTY array under `set -u` aborts with "unbound variable" — which
# would have crashed this script on the everything-worked path.
FAILED=""
for repo in "${REPOS[@]}"; do
  rc=0
  gh variable set PLANE_BASE_URL   --repo "$repo" --body "$BASE" 2>/dev/null || rc=1
  gh variable set PLANE_WORKSPACE  --repo "$repo" --body "$WS"   2>/dev/null || rc=1
  gh variable set PLANE_PROJECT_ID --repo "$repo" --body "$PID"  2>/dev/null || rc=1
  if [ $rc -eq 0 ]; then ok "$repo"; else warn "$repo — at least one variable failed to set"; FAILED="$FAILED $repo"; fi
done

# ---------------------------------------------------------------------------------
step "Read back what actually landed"
# ---------------------------------------------------------------------------------
# A green `gh variable set` is not proof the repo now has the right value.
BAD=""
for repo in "${REPOS[@]}"; do
  got=$(gh variable list --repo "$repo" --json name,value 2>/dev/null | python3 -c "
import sys,json
want={'PLANE_BASE_URL':'$BASE','PLANE_WORKSPACE':'$WS','PLANE_PROJECT_ID':'$PID'}
try: rows={v['name']:v['value'] for v in json.load(sys.stdin)}
except Exception: print('unreadable'); sys.exit(0)
bad=[k for k,v in want.items() if rows.get(k)!=v]
print('ok' if not bad else 'MISMATCH: '+','.join(bad))")
  if [ "$got" = "ok" ]; then ok "$repo verified"; else warn "$repo — $got"; BAD="$BAD $repo"; fi
done

# ---------------------------------------------------------------------------------
step "Summary"
# ---------------------------------------------------------------------------------
echo "  Vault  : api_key added to $VAULT_SECRET, ${BEFORE// /, } preserved"
echo "  Plane  : workspace $WS, project PET ($PID)"
if [ -z "$BAD" ] && [ -z "$FAILED" ]; then
  echo "  Repos  : all ${#REPOS[@]} verified"
  cat <<'EOF'

  Left to do by hand — the end-to-end test the handoff insists on:
    1. Open a throwaway PR from a pet-287-* branch.
    2. Watch the ladder: draft -> In Progress, ready -> In Review, merged -> Done,
       closed unmerged -> Todo.
    3. A green check is NOT proof. Open the work item and confirm the state changed.
    4. Then stop the tracker and confirm a merge still goes through (advisory by design):
         ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.235 \
           'cd /opt/plane && docker compose --env-file plane.env stop proxy'
         # merge a PR — it MUST NOT be blocked
         ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.235 \
           'cd /opt/plane && docker compose --env-file plane.env start proxy'
EOF
else
  echo "  Repos  : did not verify —$BAD$FAILED. Re-run, or set them by hand:"
  for repo in $BAD $FAILED; do
    echo "    gh variable set PLANE_BASE_URL   --repo $repo --body '$BASE'"
    echo "    gh variable set PLANE_WORKSPACE  --repo $repo --body '$WS'"
    echo "    gh variable set PLANE_PROJECT_ID --repo $repo --body '$PID'"
  done
  exit 1
fi
