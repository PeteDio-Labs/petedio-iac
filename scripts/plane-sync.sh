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
#   PLANE_BASE_URL     the LAN address, http://192.168.50.235:8080. Not https://plane.pdlab.dev:
#                      Cloudflare Access answers a PAT call there with a sign-in redirect (PET-610)
#   PLANE_WORKSPACE    workspace slug
#   PLANE_PROJECT_ID   project UUID. Several projects: separate the UUIDs with spaces or commas.
#   PLANE_KEYS         optional; branch prefixes that name a work item (default "pet pdl")
#   PLANE_API_KEY      PAT from Vault kv/services/plane
#   PLANE_TRANSITION   target state key (see STATE_* below)
#   HEAD_REF           the PR's head branch, e.g. pet-287-plane-ci-sync
#   PR_URL             optional; posted as a comment on first transition
#
# FORWARD ONLY (PET-490): a move to a state ranked below the item's current one
# (Backlog < Todo < In Progress < In Review < Done), or any move off Cancelled, is
# refused with a warning and no PATCH. A person moves an item backward by hand.
#
# PARTIAL MERGES (PET-490): a HEAD_REF of `<key>-<n>-part-<slug>` delivers part of the
# item, so PLANE_TRANSITION=done on it moves the item to In Review, not Done. Use it
# when the item stays open after the merge, such as for a deploy Pedro still owes.
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
# Convention: <key>-<n>-<slug>, where <key> is pet or pdl (PLANE_KEYS). Anything else is a PR without a ticket, which is
# legitimate (docs, hotfixes) — skip silently rather than warn, or the annotation
# becomes noise everyone learns to ignore.
HEAD_REF="${HEAD_REF:-}"
KEYS_RE="$(printf '%s' "${PLANE_KEYS:-pet pdl}" | tr -s ', ' '||' | sed 's/^|//; s/|$//')"
if ! [[ "$HEAD_REF" =~ ^($KEYS_RE)-([0-9]+)- ]]; then
  info "branch '$HEAD_REF' carries no <key>-<n>- prefix (keys: ${PLANE_KEYS:-pet pdl}); nothing to sync"
  exit 0
fi
KEY="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
SEQ="${BASH_REMATCH[2]}"
ITEM_KEY="$KEY-$SEQ"
info "work item: $ITEM_KEY  ·  transition: ${PLANE_TRANSITION:-<unset>}"

for v in PLANE_BASE_URL PLANE_WORKSPACE PLANE_PROJECT_ID PLANE_API_KEY PLANE_TRANSITION; do
  if [ -z "${!v:-}" ]; then warn "$v is unset — skipping sync for $ITEM_KEY"; exit 0; fi
done

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

# A `pet-<n>-part-` branch delivers part of the item, so its merge leaves the item
# open at In Review rather than closing it (PET-490). The nightly reconciler passes
# the same branch name, so it stops re-applying Done too.
if [[ "$HEAD_REF" =~ ^(pet|pdl)-[0-9]+-part- ]] && [ "$PLANE_TRANSITION" = "done" ]; then
  WANT="In Review"
  info "the -part- branch delivers part of $ITEM_KEY, so the merge keeps it open at In Review"
fi

# --- resolve the work item by its identifier -------------------------------------
# One GET to the workspace-level route `work-items/PET-<n>/` returns the item at
# any board size (PET-503). It replaces a cursor walk over the project's list
# (PET-502), which cost a request per 100 items and could repeat or hide a row
# when an item was created or deleted mid-walk. The route is workspace-wide, so the
# returned `project` must be one of PLANE_PROJECT_ID before its `id` and `state` are
# used; an item from another project is warned about and left alone.
LOOKUP_URL="${PLANE_BASE_URL%/}/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/${ITEM_KEY}/"
LOOKUP_BODY=$(mktemp) || { warn "mktemp failed — $ITEM_KEY left as-is"; exit 0; }
trap 'rm -f "$LOOKUP_BODY"' EXIT

LOOKUP_CODE=$("${CURL[@]}" -o "$LOOKUP_BODY" -w '%{http_code}' "$LOOKUP_URL" 2>/dev/null)
LOOKUP_RC=$?
if [ "$LOOKUP_RC" -ne 0 ] || [ "$LOOKUP_CODE" = "000" ]; then
  warn "Plane unreachable at ${PLANE_BASE_URL} while resolving $ITEM_KEY — left as-is (reconciler will catch it)"; exit 0
fi
# A 404 has two causes the script cannot tell apart: a missing work item, or a
# Plane without the by-identifier route. The lab's Plane (192.168.50.235:8080)
# answers an unknown route with {"error": "Page not found."}, read live for
# PET-503, and a missing item may carry the same body, so one warning names both.
case "$LOOKUP_CODE" in
  200) ;;
  404) warn "$ITEM_KEY answered 404: the branch names a work item that does not exist, or this Plane has no by-identifier route (/api/v1/workspaces/${PLANE_WORKSPACE}/work-items/$ITEM_KEY/)"; exit 0 ;;
  *)   warn "resolving $ITEM_KEY returned HTTP $LOOKUP_CODE — left as-is: $(head -c 200 "$LOOKUP_BODY" 2>/dev/null)"; exit 0 ;;
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
  warn "could not parse the work item returned for $ITEM_KEY — left as-is"; exit 0
fi
ALLOWED=0
for pid in $(printf '%s' "$PLANE_PROJECT_ID" | tr ',' ' '); do
  [ "$ITEM_PROJECT" = "$pid" ] && ALLOWED=1
done
if [ "$ALLOWED" -ne 1 ]; then
  warn "$ITEM_KEY resolved to project $ITEM_PROJECT, which is not in PLANE_PROJECT_ID (${PLANE_PROJECT_ID}) — left as-is"; exit 0
fi
info "$ITEM_KEY resolved by identifier in one GET"

# The states and the PATCH use the item's own project, so one run serves every project
# listed in PLANE_PROJECT_ID.
API="${PLANE_BASE_URL%/}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${ITEM_PROJECT}"

# --- look up the target state ----------------------------------------------------
STATES=$("${CURL[@]}" "${API}/states/?per_page=100" 2>/dev/null) || {
  warn "Plane unreachable at ${PLANE_BASE_URL} — $ITEM_KEY left as-is (reconciler will catch it)"; exit 0; }

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


# --- idempotent: only PATCH when the state actually differs ----------------------
if [ "$CUR_STATE" = "$STATE_ID" ]; then
  info "$ITEM_KEY already $WANT — no change"
  exit 0
fi

# --- backward-move guard ---------------------------------------------------------
# A sync only ever moves an item forward (PET-490): a reconcile must not reopen a
# Done item, and a closed or drafted PR must not pull an item back. The current
# state's name and group come from the states list fetched above, so the guard
# costs no request. Rank by name, then by Plane's state group for a name this
# table does not know. Cancelled, by name or group, is terminal. A state the list
# does not hold cannot be ranked, so the move goes ahead as before.
IFS=$'\t' read -r CUR_NAME VERDICT <<<"$(printf '%s' "$STATES" | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d if isinstance(d, list) else (d.get('results') or [])
cur_id, want = sys.argv[1], sys.argv[2].lower()
by_name = {'backlog': 0, 'todo': 1, 'in progress': 2, 'in review': 3, 'done': 4}
by_group = {'backlog': 0, 'triage': 0, 'unstarted': 1, 'started': 2, 'completed': 4}
cur = next((s for s in rows if s.get('id') == cur_id), None)
if cur is None:
    print('-\tunranked'); sys.exit(0)
name = str(cur.get('name') or '-'); group = str(cur.get('group') or '').lower()
if name.lower() == 'cancelled' or group == 'cancelled':
    print(name + '\trefuse'); sys.exit(0)
rank = by_name.get(name.lower(), by_group.get(group))
if rank is None:
    print(name + '\tunranked')
else:
    print(name + '\t' + ('refuse' if by_name[want] < rank else 'forward'))
" "$CUR_STATE" "$WANT" 2>/dev/null)"

case "${VERDICT:-}" in
  refuse)
    warn "$ITEM_KEY is $CUR_NAME; refused the move to $WANT (backward-move guard, PET-490)"
    exit 0 ;;
  forward) ;;
  *) info "$ITEM_KEY current state ${CUR_NAME:-?} has no rank; the guard does not apply" ;;
esac

CODE=$("${CURL[@]}" -o /tmp/plane-patch.json -w '%{http_code}' \
  -X PATCH "${API}/work-items/${ITEM_ID}/" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1]}))' "$STATE_ID")" 2>/dev/null)

case "$CODE" in
  2*) info "$ITEM_KEY → $WANT ✓" ;;
  *)  warn "PATCH returned HTTP $CODE for $ITEM_KEY — $(head -c 200 /tmp/plane-patch.json 2>/dev/null)"; exit 0 ;;
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
