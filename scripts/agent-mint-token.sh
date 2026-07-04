#!/usr/bin/env bash
# agent-mint-token.sh — mint a short-lived GitHub App installation access token for a loop
# bot identity (worker | reviewer | engine) and print it to stdout (use as GH_TOKEN). (PET-176)
#
# The fleet authors and reviews under DISTINCT least-privilege GitHub Apps so the
# reviewer is never self-blocked from reviewing the worker's/engine's PR. Each App's token is minted
# on demand — sign a <=10-min JWT with the App PEM, exchange it for a 1-hour installation
# token — so NOTHING long-lived sits on the host. Identity facts come from Vault
# kv/services/agent-loop (<role>_app_id / <role>_installation_id / <role>_app_pem), path
# reference only; UPPER-prefixed env vars override for testing.
#
#   worker   -> petedio-worker[bot]   (contents:write, pull_requests:write) — push + open PR
#   reviewer -> petedio-reviewer[bot] (contents:read,  pull_requests:write) — formal reviews
#   engine   -> petedio-engine[bot]   (contents:write, pull_requests:write) — push + open PR,
#               NO merge (Bucket-B new-effect-kind authoring, PET-184; asymmetrically weaker
#               model than the reviewer, so the reviewer stays the stronger gate)
#   merge    -> petedio-merge[bot]    (contents:write, pull_requests:write) — the Bucket-A
#               auto-merge identity (PET-185, scripts/automerge-poll.sh). A FOURTH distinct
#               App so the reviewer never merges and the authors structurally can't.
# OPERATOR: worker_app_id / reviewer_app_id / engine_app_id in Vault MUST be THREE DIFFERENT
# GitHub Apps — identical IDs collapse the identities into one actor and GitHub's self-review
# block returns (defeating PET-176/PET-184). Verify they differ when seeding kv/services/agent-loop.
#
# Usage:
#   GH_TOKEN="$(scripts/agent-mint-token.sh worker)"   gh pr create ...
#   GH_TOKEN="$(scripts/agent-mint-token.sh reviewer)" gh pr review ...
#   GH_TOKEN="$(scripts/agent-mint-token.sh engine)"   gh pr create ...
# Env overrides (UPPER role prefix): WORKER_APP_ID / WORKER_INSTALLATION_ID /
#   WORKER_APP_PEM (contents) | WORKER_APP_PEM_FILE (path); same for REVIEWER_* / ENGINE_*.
# The token is printed once — capture it into GH_TOKEN, never log it.
set -euo pipefail
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

ROLE="${1:-}"
case "$ROLE" in worker | reviewer | engine | merge) ;; *) die "usage: $(basename "$0") <worker|reviewer|engine|merge>" ;; esac
PREFIX="$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')" # WORKER / REVIEWER

for t in openssl curl python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

# env-override indirection: ${PREFIX}_APP_ID / _INSTALLATION_ID / _APP_PEM(_FILE)
eval "APP_ID=\"\${${PREFIX}_APP_ID:-}\""
eval "INSTALL_ID=\"\${${PREFIX}_INSTALLATION_ID:-}\""
eval "PEM=\"\${${PREFIX}_APP_PEM:-}\""
eval "PEM_FILE=\"\${${PREFIX}_APP_PEM_FILE:-}\""
[ -n "$PEM_FILE" ] && PEM="$(cat "$PEM_FILE")"

# Fill any missing piece from Vault (the loop host has a Vault Agent token on disk).
if [ -z "$APP_ID" ] || [ -z "$INSTALL_ID" ] || [ -z "$PEM" ]; then
  command -v vault >/dev/null || die "vault not in PATH and ${PREFIX}_* not fully set via env."
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
  export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"
  [ -n "$APP_ID" ] || APP_ID="$(vault kv get -field="${ROLE}_app_id" kv/services/agent-loop)"
  [ -n "$INSTALL_ID" ] || INSTALL_ID="$(vault kv get -field="${ROLE}_installation_id" kv/services/agent-loop)"
  [ -n "$PEM" ] || PEM="$(vault kv get -field="${ROLE}_app_pem" kv/services/agent-loop)"
fi
[ -n "$APP_ID" ] && [ -n "$INSTALL_ID" ] && [ -n "$PEM" ] || die "missing ${ROLE} app_id / installation_id / pem."

now="$(date +%s)"
h="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
# iat back-dated 60s for clock skew; exp 480s out → a 540s window, safely under GitHub's
# HARD 600s (exp-iat) ceiling (was exactly 600 = zero margin, a latent mint failure).
p="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 480))" "$APP_ID" | b64url)"
sig="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign <(printf '%s' "$PEM") -binary | b64url)"
jwt="${h}.${p}.${sig}"

# The JWT is App-bearer-equivalent for its lifetime — keep it OFF curl's argv (where any
# local `ps` / /proc/<pid>/cmdline could read it). printf is a bash builtin, so piping the
# header via stdin (`-H @-`) never exposes the JWT on an external process's command line.
# The token-exchange POST has no body, so stdin is free for the header.
resp="$(printf 'Authorization: Bearer %s\n' "$jwt" | curl -sS -X POST \
  -H @- \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens")"

token="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("token") or "")
except Exception:
    print("")')"
[ -n "$token" ] || die "mint failed for ${ROLE}. API said: $(printf '%s' "$resp" | head -c 200)"
printf '%s\n' "$token"
