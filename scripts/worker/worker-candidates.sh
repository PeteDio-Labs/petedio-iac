#!/usr/bin/env bash
# worker-candidates.sh — list Co-latro issues the worker MAY pick up (PET-179).
#
# The WORKER half of the two-agent system (PET-179), step 1: the "poll". READ-ONLY by
# construction — it never claims, branches, comments, or moves status. It prints a JSON
# array of candidate issues the worker is allowed to author: Co-latro issues that are in
# **Todo** and carry the `worker-ok` label. Each is annotated with the PET-<n> key, title,
# the repo it maps to, and a `branch-slug` the worker turns into `pet-<n>-<slug>`.
#
# LINEAR ACCESS — the asymmetry vs the reviewer. The reviewer's candidate list is open PRs,
# which `gh` sees directly. The worker's candidates are *Linear issues* (Todo + worker-ok),
# which live ONLY in Linear — and as of PET-179 the homelab still has **no provisioned
# Linear API token** (`kv/services/linear`, field `api_key`, is the documented-but-unfilled
# path PET-145/147 + mission-control all reference; see docs/runbooks/loop-stall-detection.md
# "Manual steps"). So this script does the cleanest thing it CAN:
#   * If a Linear token is available — env LINEAR_API_KEY, or self-served from Vault at
#     WORKER_LINEAR_VAULT_PATH via the on-disk Vault Agent token (PET-141) — it queries the
#     Linear GraphQL API (curl + python3, jq isn't on the loop host) and emits the real
#     candidate array.
#   * If no token is reachable, it follows the reviewer/stall-detection precedent: the heavy
#     Linear reasoning is Claude's via the Linear MCP per docs/runbooks/worker-loop.md. The
#     script then prints `[]` on stdout and a one-line note on stderr telling Claude to
#     enumerate candidates through the MCP. Exit is still 0 — "no token" is a known mode,
#     not a harness error.
#
# What's the SCRIPT vs what's CLAUDE (documented so the boundary is unambiguous):
#   * SCRIPT (with a token): the mechanical filter — Todo + worker-ok + Co-latro team,
#     shaped into {key,title,repo,branch-slug}.
#   * CLAUDE (always): picking ONE issue, reading its full spec, the round-trip cap, and any
#     judgment about readiness. A shell script can't reason over an issue body.
#
# Usage:
#   scripts/worker/worker-candidates.sh
#
# Env (all optional):
#   LINEAR_API_KEY            Linear personal/api key. If set, the GraphQL path is used.
#   WORKER_LINEAR_VAULT_PATH  Vault KV path to self-serve the key when LINEAR_API_KEY is
#                             unset (default: kv/services/linear, field `api_key`). Read via
#                             the Vault Agent token on disk (~/.vault-token) — never printed.
#   WORKER_LINEAR_TEAM_KEY    Linear team key to scope the query (default: PET).
#   WORKER_OK_LABEL           the gate label (default: worker-ok).
#   WORKER_TODO_STATE         Linear workflow state name to match (default: Todo).
#   WORKER_REPOS_MAP          "team-or-project-substring=owner/repo;…" hints to resolve an
#                             issue to its repo. Default maps Co-latro work to the backend;
#                             Claude corrects backend-vs-frontend from the issue body.
#
# Output (stdout): JSON array, one object per candidate:
#   {"key","title","repo","branch_slug","state","labels"}
# Exit 0 with `[]` when nothing matches OR no Linear token is reachable (see stderr note).
# No secret (Linear key, Vault token) is ever printed.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
note() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

command -v python3 >/dev/null || die "python3 not in PATH (jq isn't on the loop host)."

TEAM_KEY="${WORKER_LINEAR_TEAM_KEY:-PET}"
OK_LABEL="${WORKER_OK_LABEL:-worker-ok}"
TODO_STATE="${WORKER_TODO_STATE:-Todo}"
VAULT_PATH="${WORKER_LINEAR_VAULT_PATH:-kv/services/linear}"
# Default repo hint: Co-latro issues land in the backend unless the body says frontend.
REPOS_MAP="${WORKER_REPOS_MAP:-co-latro=PeteDio-Labs/co-latro-backend}"

# --- resolve a Linear key WITHOUT printing it -------------------------------------------
# Precedence: explicit env, then Vault self-serve (Vault Agent token on disk). An absent
# key is NOT fatal — it drops us into the MCP-delegation mode below.
LINEAR_KEY="${LINEAR_API_KEY:-}"
if [ -z "$LINEAR_KEY" ] && command -v vault >/dev/null 2>&1; then
  # `vault kv get -field=` prints ONLY the field value; we capture it, never echo it.
  LINEAR_KEY="$(vault kv get -field=api_key "$VAULT_PATH" 2>/dev/null || true)"
fi

if [ -z "$LINEAR_KEY" ]; then
  note "No Linear token (env LINEAR_API_KEY / Vault $VAULT_PATH:api_key). No provisioned"
  note "token on the loop host yet (PET-145/147). Claude: enumerate $OK_LABEL + $TODO_STATE"
  note "Co-latro candidates via the Linear MCP per docs/runbooks/worker-loop.md, then pick one."
  printf '[]\n'
  exit 0
fi

command -v curl >/dev/null || die "curl not in PATH (needed for the Linear GraphQL query)."

# --- query Linear GraphQL: Todo + worker-ok issues on the team --------------------------
# Keep the query small and let python do the shaping. We filter by state name + label name
# server-side; the team scope is by key. `first: 50` is plenty for a candidate poll.
# shellcheck disable=SC2016  # $teamKey/$state/$label are GraphQL variables — literal on purpose.
QUERY='query($teamKey:String!,$state:String!,$label:String!){issues(first:50,filter:{team:{key:{eq:$teamKey}},state:{name:{eq:$state}},labels:{name:{eq:$label}}}){nodes{identifier title state{name} labels{nodes{name}}}}}'

REQ_BODY="$(
  TEAM_KEY="$TEAM_KEY" TODO_STATE="$TODO_STATE" OK_LABEL="$OK_LABEL" QUERY="$QUERY" \
  python3 <<'PY'
import json, os
print(json.dumps({
    "query": os.environ["QUERY"],
    "variables": {
        "teamKey": os.environ["TEAM_KEY"],
        "state": os.environ["TODO_STATE"],
        "label": os.environ["OK_LABEL"],
    },
}))
PY
)"

# The key goes in the Authorization header only — never on the command line in a way that
# lands in argv-visible output, and never echoed. curl reads the body from stdin (@-).
RESP="$(
  printf '%s' "$REQ_BODY" | curl -fsS \
    -H "Authorization: $LINEAR_KEY" \
    -H "Content-Type: application/json" \
    --data @- \
    https://api.linear.app/graphql 2>/dev/null
)" || die "Linear GraphQL request failed (key valid? network up?). No secret printed."

REPOS_MAP="$REPOS_MAP" python3 - "$RESP" <<'PY'
import json, re, sys

resp = json.loads(sys.argv[1])
import os
# Parse "substr=owner/repo;substr2=owner/repo2" into ordered (substr, repo) pairs.
repo_pairs = []
for part in os.environ.get("REPOS_MAP", "").split(";"):
    part = part.strip()
    if not part or "=" not in part:
        continue
    sub, repo = part.split("=", 1)
    repo_pairs.append((sub.strip().lower(), repo.strip()))

def slugify(title):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s[:50].rstrip("-") or "issue"

def repo_for(title):
    t = title.lower()
    # Body-level backend/frontend hints win; else first matching map substring; else "".
    if "frontend" in t:
        return "PeteDio-Labs/co-latro-frontend"
    if "backend" in t:
        return "PeteDio-Labs/co-latro-backend"
    for sub, repo in repo_pairs:
        if sub in t or sub == "co-latro":
            return repo
    return repo_pairs[0][1] if repo_pairs else ""

nodes = (((resp or {}).get("data") or {}).get("issues") or {}).get("nodes") or []
out = []
for n in nodes:
    title = n.get("title", "") or ""
    out.append({
        "key": n.get("identifier", ""),
        "title": title,
        "repo": repo_for(title),
        "branch_slug": slugify(title),
        "state": (n.get("state") or {}).get("name", ""),
        "labels": [l.get("name", "") for l in ((n.get("labels") or {}).get("nodes") or [])],
    })

json.dump(out, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
