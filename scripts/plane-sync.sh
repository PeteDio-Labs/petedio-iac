#!/usr/bin/env bash
# Move a Plane work item's state to match what just happened to its PR.
#
# Replaces the GitHub↔Linear auto-advance that was uninstalled 2026-08-13. Plane's
# own GitHub integration is a PAID feature (Pro, $6/seat) and is NOT in the
# self-hosted Community Edition, so CI does it instead — see the vault note
# `Projects/plane-cutover.md`.
#
#   PLANE_TRANSITION=in-progress|in-review|done|todo  ./scripts/plane-sync.sh
#
# Inputs, all via ENVIRONMENT (never argv, never workflow interpolation — the
# branch name is attacker-controlled on a public repo, see the injection note in
# .github/workflows/plane-sync.yml):
#   PLANE_BASE_URL     e.g. https://plane.pdlab.dev  (or the LAN address)
#   PLANE_WORKSPACE    workspace slug
#   PLANE_PROJECT_ID   project UUID
#   PLANE_API_KEY      PAT from Vault kv/services/plane
#   PLANE_TRANSITION   target state key (see STATE_* below)
#   HEAD_REF           the PR's head branch, e.g. pet-287-plane-ci-sync
#   PR_URL             optional; posted as a comment on first transition
#
# ADVISORY BY DESIGN: every failure path exits 0 with a ::warning:: annotation.
# Plane is a homelab LXC — it being down must never block a merge across nine
# repos. Drift is caught by the nightly reconciler (plane-reconcile.yml).
#
# NOTE: macOS bash 3.2 compatible (no associative arrays) — the runner is Linux,
# but this is also run by hand during the pilot.

set -uo pipefail

warn() { echo "::warning title=plane-sync::$*"; }
info() { echo "  $*"; }

# --- resolve the work item number from the branch --------------------------------
# Convention: pet-<n>-<slug>. Anything else is a PR without a ticket, which is
# legitimate (docs, hotfixes) — skip silently rather than warn, or the annotation
# becomes noise everyone learns to ignore.
HEAD_REF="${HEAD_REF:-}"
if ! [[ "$HEAD_REF" =~ ^pet-([0-9]+)- ]]; then
  info "branch '$HEAD_REF' carries no pet-<n>- prefix; nothing to sync"
  exit 0
fi
SEQ="${BASH_REMATCH[1]}"
info "work item: PET-$SEQ  ·  transition: ${PLANE_TRANSITION:-<unset>}"

for v in PLANE_BASE_URL PLANE_WORKSPACE PLANE_PROJECT_ID PLANE_API_KEY PLANE_TRANSITION; do
  if [ -z "${!v:-}" ]; then warn "$v is unset — skipping sync for PET-$SEQ"; exit 0; fi
done

API="${PLANE_BASE_URL%/}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PLANE_PROJECT_ID}"
CURL=(curl -sS --max-time 15 -H "X-API-Key: ${PLANE_API_KEY}" -H "Content-Type: application/json")

# Map our transition keys to the Plane state NAMES. Names, not UUIDs: UUIDs differ
# per project and would have to be re-pinned every time a project is recreated.
case "$PLANE_TRANSITION" in
  in-progress) WANT="In Progress" ;;
  in-review)   WANT="In Review"   ;;
  done)        WANT="Done"        ;;
  todo)        WANT="Todo"        ;;
  *) warn "unknown PLANE_TRANSITION '$PLANE_TRANSITION'"; exit 0 ;;
esac

# --- look up the target state ----------------------------------------------------
STATES=$("${CURL[@]}" "${API}/states/?per_page=100" 2>/dev/null) || {
  warn "Plane unreachable at ${PLANE_BASE_URL} — PET-$SEQ left as-is (reconciler will catch it)"; exit 0; }

STATE_ID=$(printf '%s' "$STATES" | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
want = sys.argv[1].lower()
for s in (d.get('results') or d if isinstance(d, list) else d.get('results', [])):
    if str(s.get('name','')).lower() == want:
        print(s['id']); break
" "$WANT" 2>/dev/null)

if [ -z "$STATE_ID" ]; then
  warn "no state named '$WANT' in this project — create it in Plane (Community Edition ships Backlog/Todo/In Progress/Done/Cancelled; 'In Review' must be added by hand)"
  exit 0
fi

# --- resolve the work item by its identifier -------------------------------------
# One GET to the workspace-level route `work-items/PET-<n>/` returns the item at
# any board size (PET-503). It replaces a cursor walk over the project's list
# (PET-502), which cost a request per 100 items and could repeat or hide a row
# when an item was created or deleted mid-walk. The route is workspace-wide, so the
# returned `project` must equal PLANE_PROJECT_ID before its `id` and `state` are
# used; an item from another project is warned about and left alone.
LOOKUP_URL="${PLANE_BASE_URL%/}/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/PET-${SEQ}/"
LOOKUP_BODY=$(mktemp) || { warn "mktemp failed — PET-$SEQ left as-is"; exit 0; }
trap 'rm -f "$LOOKUP_BODY"' EXIT

LOOKUP_CODE=$("${CURL[@]}" -o "$LOOKUP_BODY" -w '%{http_code}' "$LOOKUP_URL" 2>/dev/null)
LOOKUP_RC=$?
if [ "$LOOKUP_RC" -ne 0 ] || [ "$LOOKUP_CODE" = "000" ]; then
  warn "Plane unreachable at ${PLANE_BASE_URL} while resolving PET-$SEQ — left as-is (reconciler will catch it)"; exit 0
fi
case "$LOOKUP_CODE" in
  200) ;;
  404) warn "PET-$SEQ not found in workspace ${PLANE_WORKSPACE} — the branch names a work item that does not exist"; exit 0 ;;
  *)   warn "resolving PET-$SEQ returned HTTP $LOOKUP_CODE — left as-is: $(head -c 200 "$LOOKUP_BODY" 2>/dev/null)"; exit 0 ;;
esac

# One line: project id state. A blank line means the body was not a work item.
read -r ITEM_PROJECT ITEM_ID CUR_STATE <<<"$(python3 -c "
import sys, json
try: w = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
if not isinstance(w, dict) or not w.get('id'): sys.exit(0)
def ref(v): return (v.get('id') if isinstance(v, dict) else v) or '-'
print(ref(w.get('project')), w['id'], ref(w.get('state')))
" "$LOOKUP_BODY" 2>/dev/null)"

if [ -z "${ITEM_ID:-}" ]; then
  warn "could not parse the work item returned for PET-$SEQ — left as-is"; exit 0
fi
if [ "$ITEM_PROJECT" != "$PLANE_PROJECT_ID" ]; then
  warn "PET-$SEQ resolved to project $ITEM_PROJECT, not ${PLANE_PROJECT_ID} — left as-is"; exit 0
fi
info "PET-$SEQ resolved by identifier in one GET"

# --- idempotent: only PATCH when the state actually differs ----------------------
if [ "$CUR_STATE" = "$STATE_ID" ]; then
  info "PET-$SEQ already $WANT — no change"
  exit 0
fi

CODE=$("${CURL[@]}" -o /tmp/plane-patch.json -w '%{http_code}' \
  -X PATCH "${API}/work-items/${ITEM_ID}/" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1]}))' "$STATE_ID")" 2>/dev/null)

case "$CODE" in
  2*) info "PET-$SEQ → $WANT ✓" ;;
  *)  warn "PATCH returned HTTP $CODE for PET-$SEQ — $(head -c 200 /tmp/plane-patch.json 2>/dev/null)"; exit 0 ;;
esac

# --- link the PR back, once ------------------------------------------------------
# Only on the first transition, so a five-commit PR does not leave five identical
# comments. Failure here is cosmetic and never escalates.
if [ -n "${PR_URL:-}" ] && [ "$PLANE_TRANSITION" = "in-progress" ]; then
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"comment_html": "<p>PR: <a href=\"%s\">%s</a></p>" % (sys.argv[1], sys.argv[1])}))' "$PR_URL")
  "${CURL[@]}" -o /dev/null -X POST "${API}/work-items/${ITEM_ID}/comments/" -d "$BODY" 2>/dev/null \
    && info "linked $PR_URL" || warn "could not post the PR link (cosmetic)"
fi

exit 0
