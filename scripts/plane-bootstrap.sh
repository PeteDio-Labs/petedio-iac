#!/usr/bin/env bash
# plane-bootstrap.sh — create the PET project, prove the sequence_id decision, and add
# the "In Review" state the CI ladder needs.
#
# RUN THIS AFTER creating the instance admin at http://192.168.50.235:8080/god-mode/
# and generating a personal access token (Profile settings -> Personal access tokens).
# Account creation is deliberately NOT automated here.
#
#   PLANE_API_KEY=plane_api_... ./scripts/plane-bootstrap.sh
#
# Idempotent: re-running finds the existing project and state and changes nothing.
set -uo pipefail

BASE="${PLANE_BASE_URL:-http://192.168.50.235:8080}"
WS="${PLANE_WORKSPACE:-}"
KEY="${PLANE_API_KEY:-}"
SEQ_START="${PLANE_SEQ_START:-287}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
[ -n "$KEY" ] || die "PLANE_API_KEY is unset. Generate one in Plane: Profile settings -> Personal access tokens."

API="$BASE/api/v1"
CURL=(curl -sS --max-time 20 -H "X-API-Key: $KEY" -H "Content-Type: application/json")

step "Resolving the workspace"
if [ -z "$WS" ]; then
  WS=$("${CURL[@]}" "$API/workspaces/" 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d.get('results', d if isinstance(d,list) else [])
print(rows[0]['slug'] if rows else '')" )
fi
[ -n "$WS" ] || die "no workspace found — create one in the UI first, or set PLANE_WORKSPACE."
echo "  workspace: $WS"

step "Project with identifier PET"
PROJECTS=$("${CURL[@]}" "$API/workspaces/$WS/projects/" 2>/dev/null)
PID=$(printf '%s' "$PROJECTS" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d.get('results', d if isinstance(d,list) else []):
    if str(p.get('identifier','')).upper()=='PET': print(p['id']); break")

if [ -z "$PID" ]; then
  PID=$("${CURL[@]}" -X POST "$API/workspaces/$WS/projects/" \
    -d '{"name":"PeteDio","identifier":"PET","description":"Homelab + apps. Continues the PET numbering from Linear."}' \
    2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
  [ -n "$PID" ] || die "could not create the PET project."
  echo "  created project PET ($PID)"
else
  echo "  project PET already exists ($PID)"
fi

# ---------------------------------------------------------------------------------
# THE DECISION THIS SCRIPT EXISTS TO SETTLE.
#
# Plane assigns sequence_id itself, starting at 1. The create-work-item API *lists*
# sequence_id as an accepted body field but does not document whether it is honoured.
# Every commit, branch and PR title in the estate carries PET-<n>, so continuing from
# 287 rather than restarting at 1 is worth one experiment.
# ---------------------------------------------------------------------------------
step "Does the API honour an explicit sequence_id?"
RESP=$("${CURL[@]}" -X POST "$API/workspaces/$WS/projects/$PID/work-items/" \
  -d "{\"name\":\"Numbering probe — safe to delete\",\"sequence_id\":$SEQ_START}" 2>/dev/null)
GOT=$(printf '%s' "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('sequence_id',''))" 2>/dev/null)
WID=$(printf '%s' "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ "$GOT" = "$SEQ_START" ]; then
  echo "  ✅ HONOURED — the probe is PET-$GOT. Numbering continues from Linear."
  echo "     Keep this work item as PET-$SEQ_START (rename it) or delete it and re-create."
else
  echo "  ❌ IGNORED — asked for $SEQ_START, got ${GOT:-<none>}."
  cat <<'EOF'
     Fall back, in order of preference:
       1. Set the counter in Postgres on 231 (self-hosting is what makes this legitimate).
       2. Burn numbers: create and delete throwaway items until the counter reaches 287.
          Plane does not roll the counter back on delete.
       3. Accept PET-1 and treat the old range as historical. Last resort — it makes
          every PET-<n> in git ambiguous.
EOF
fi
[ -n "$WID" ] && echo "  probe work item id: $WID"

step "State: In Review"
STATES=$("${CURL[@]}" "$API/workspaces/$WS/projects/$PID/states/?per_page=100" 2>/dev/null)
HAVE=$(printf '%s' "$STATES" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
names=[str(s.get('name','')).lower() for s in d.get('results', d if isinstance(d,list) else [])]
print('yes' if 'in review' in names else 'no')")
if [ "$HAVE" = "yes" ]; then
  echo "  already present"
else
  "${CURL[@]}" -X POST "$API/workspaces/$WS/projects/$PID/states/" \
    -d '{"name":"In Review","group":"started","color":"#F59E0B","description":"PR open and awaiting review — set by plane-sync.yml"}' \
    >/dev/null 2>&1 && echo "  created (CE ships Backlog/Todo/In Progress/Done/Cancelled — this rung is ours)" \
    || echo "  ⚠ could not create it; add it by hand or the ladder's middle rung will no-op"
fi

step "Values for the repo variables"
cat <<EOF
  PLANE_BASE_URL       = $BASE
  PLANE_WORKSPACE      = $WS
  PLANE_PROJECT_ID = $PID

  gh variable set PLANE_BASE_URL       --repo PeteDio-Labs/petedio-iac --body '$BASE'
  gh variable set PLANE_WORKSPACE      --repo PeteDio-Labs/petedio-iac --body '$WS'
  gh variable set PLANE_PROJECT_ID --repo PeteDio-Labs/petedio-iac --body '$PID'
EOF
