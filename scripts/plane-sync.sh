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

# --- find the work item by its sequence id ---------------------------------------
# The list is paged, and the board outgrew one page: with 213 items, a single GET
# of 100 missed PET-386 and warned that the branch named an item that did not
# exist (PET-502). Walk the pages with Plane's own cursor, `per_page:page:is_prev`,
# until the sequence id matches or `next_page_results` turns false. The list is
# newest first, so a live item resolves on page one and only an old one pays for
# the walk. scripts/weekly-audit/plane-pull.sh in the workspace pages the same way.
#
# The cursor is an offset, so an item created mid-walk repeats one row and an item
# deleted mid-walk can hide one. Both are rare, and the nightly reconciler runs
# this script again, so neither is worth a sort key here.
PER_PAGE=100
MAX_PAGES=50            # 5000 items: a bound against a list that never ends
CURSOR="${PER_PAGE}:0:0"
SCANNED=0
PAGES=0
TOTAL="?"
ITEM_ID=""
CUR_STATE=""
while :; do
  PAGE=$("${CURL[@]}" "${API}/work-items/?per_page=${PER_PAGE}&cursor=${CURSOR}&fields=id,sequence_id,name,state" 2>/dev/null) || {
    warn "could not list work items (page $((PAGES + 1)), $SCANNED scanned so far) — PET-$SEQ left as-is"; exit 0; }
  PAGES=$((PAGES + 1))

  # One line per page: rows total next_cursor more [id state]. A blank line means
  # the body was not the list this script expects.
  read -r ROWS TOTAL NEXT MORE FOUND_ID FOUND_STATE <<<"$(printf '%s' "$PAGE" | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(d, dict): d = {'results': d}
rows = d.get('results') or []
seq = int(sys.argv[1])
hit = next((w for w in rows if w.get('sequence_id') == seq), None)
print(len(rows), d.get('total_count', '?'), d.get('next_cursor') or '-',
      1 if d.get('next_page_results') else 0,
      hit['id'] if hit else '', (hit.get('state') or '-') if hit else '')
" "$SEQ" 2>/dev/null)"

  if [ -z "${ROWS:-}" ]; then
    warn "could not parse the work-item list (page $PAGES) — PET-$SEQ left as-is"; exit 0
  fi
  SCANNED=$((SCANNED + ROWS))
  if [ -n "${FOUND_ID:-}" ]; then
    ITEM_ID="$FOUND_ID"; CUR_STATE="$FOUND_STATE"; break
  fi
  # Stop on the last page, on an empty page, and on a cursor that does not advance.
  if [ "$MORE" != "1" ] || [ "$ROWS" -eq 0 ] || [ "$NEXT" = "-" ] || [ "$NEXT" = "$CURSOR" ]; then
    break
  fi
  if [ "$PAGES" -ge "$MAX_PAGES" ]; then
    warn "gave up after $PAGES pages ($SCANNED of $TOTAL work items) without finding PET-$SEQ — left as-is"; exit 0
  fi
  CURSOR="$NEXT"
done

if [ -z "$ITEM_ID" ]; then
  warn "PET-$SEQ not found in project ${PLANE_PROJECT_ID} after scanning $SCANNED of $TOTAL work items over $PAGES page(s) — the branch names a work item that does not exist"
  exit 0
fi
info "PET-$SEQ found on page $PAGES ($SCANNED of $TOTAL work items scanned)"

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
