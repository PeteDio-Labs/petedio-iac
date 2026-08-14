#!/usr/bin/env bash
# plane-bootstrap.sh — create the PET project and add the "In Review" state the CI
# ladder needs.
#
# RUN THIS AFTER creating the instance admin at http://192.168.50.235:8080/god-mode/
# and generating a personal access token (Profile settings -> Personal access tokens,
# i.e. /settings/profile/api-tokens/). Account creation is deliberately NOT automated.
#
#   PLANE_API_KEY=plane_api_... ./scripts/plane-bootstrap.sh
#
# Idempotent, and now actually so: re-running finds the existing project and state and
# creates nothing. It no longer probes sequence_id — see the note below for why that
# question is closed and where work-item numbering really lives.
set -uo pipefail

BASE="${PLANE_BASE_URL:-http://192.168.50.235:8080}"
WS="${PLANE_WORKSPACE:-}"
KEY="${PLANE_API_KEY:-}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
[ -n "$KEY" ] || die "PLANE_API_KEY is unset. Generate one in Plane: Profile settings -> Personal access tokens."

API="$BASE/api/v1"
CURL=(curl -sS --max-time 20 -H "X-API-Key: $KEY" -H "Content-Type: application/json")

step "Resolving the workspace"
# Plane has NO list-workspaces endpoint. Every public route is scoped under
# /workspaces/<slug>/, as plane-sync.sh:50 has always done, so the slug is an INPUT and
# there is nothing to discover. This block used to call GET /api/v1/workspaces/, get
# nothing back because the route does not exist, and die with "no workspace found —
# create one in the UI first" while a workspace plainly existed.
WS="${WS:-petedio}"

# Validating against a workspace-scoped route checks the key and the slug at once, and
# distinguishes the failures instead of blaming the token for all of them. The status is
# what matters, not the body: before this script has run, an EMPTY project list is the
# correct answer.
WS_CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$API/workspaces/$WS/projects/" 2>/dev/null)
case "$WS_CODE" in
  200)     : ;;
  401|403) die "the API key was rejected (HTTP $WS_CODE). Regenerate it at $BASE/settings/profile/api-tokens/ (note: /settings/, the shorter path redirects)." ;;
  404)     die "workspace '$WS' not found (HTTP 404). Create it in the UI, or set PLANE_WORKSPACE=<slug>." ;;
  000)     die "no response from $BASE — is Tailscale up?" ;;
  *)       die "unexpected HTTP $WS_CODE from $API/workspaces/$WS/projects/" ;;
esac
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
# THE NUMBERING QUESTION — SETTLED 2026-08-13. DO NOT RE-PROBE.
#
# There used to be an experiment here that POSTed a work item with an explicit
# sequence_id to find out whether the API honoured it. It does not, and never could:
# Issue.save() overwrites the field unconditionally on insert. From Plane's own source
# at the deployed tag v1.4.1, apps/api/plane/db/models/issue.py:
#
#     last_sequence = IssueSequence.objects.filter(project=self.project).aggregate(
#         largest=models.Max("sequence"))["largest"]
#     self.sequence_id = last_sequence + 1 if last_sequence else 1
#
# So the probe could only ever come back "IGNORED", while creating a junk work item on
# every run of a script whose header promises idempotence. It is gone.
#
# The counter is the `issue_sequences` table (column `sequence`, keyed by project) —
# NOT issues.sequence_id, which is only the display number. To continue numbering,
# raise max(sequence) for the project; the next work item gets max+1. Deleting items
# does not roll it back (issue_sequences.issue is ON DELETE SET_NULL, deliberately).
#
# Done once for PET at 286 so the first real item became PET-287. Full method, guards
# and evidence: vault Projects/plane-handoff.md.
# ---------------------------------------------------------------------------------

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
