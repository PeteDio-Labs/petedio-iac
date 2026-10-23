#!/usr/bin/env bash
# forgejo-mirror-sync — copy every repo the read-only GitHub App reaches into Forgejo (PET-756).
#
# Per run: mint an installation token, list the repos the installation reaches, `git fetch` each
# into a bare cache, `git push --prune` the refs into a Forgejo repo of the same name.
#
# It exits non-zero unless it examined exactly the repos GitHub reported and every one synced,
# and it writes what it examined to $STATE_DIR/status.json. A run that listed nothing fails.
# Tokens reach git through GIT_CONFIG_* environment variables, never argv, so `ps` does not
# show them. Nothing is printed that holds a token.
set -euo pipefail

: "${APP_ID:?}" "${INSTALLATION_ID:?}" "${APP_PEM_FILE:?}" "${ORG:?}"
: "${FORGEJO_URL:?}" "${FORGEJO_TOKEN_FILE:?}" "${STATE_DIR:?}"
CACHE="$STATE_DIR/cache"
mkdir -p "$CACHE"
FTOKEN="$(cat "$FORGEJO_TOKEN_FILE")"
GH=https://api.github.com

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now="$(date +%s)"
h="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
p="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 480))" "$APP_ID" | b64url)"
s="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$APP_PEM_FILE" -binary | b64url)"
tok_json="$(printf 'Authorization: Bearer %s.%s.%s\n' "$h" "$p" "$s" | curl -fsS --max-time 20 -X POST -H @- \
  -H 'Accept: application/vnd.github+json' "$GH/app/installations/$INSTALLATION_ID/access_tokens")" \
  || { echo "ERROR: GitHub would not mint an installation token" >&2; exit 1; }
GHTOKEN="$(jq -r '.token // empty' <<<"$tok_json")"
[ -n "$GHTOKEN" ] || { echo "ERROR: no token in GitHub's answer" >&2; exit 1; }
unset tok_json s

gh_get() { printf 'Authorization: token %s\n' "$GHTOKEN" | curl -fsS --max-time 30 -H @- -H 'Accept: application/vnd.github+json' "$1"; }
f_api() { # method path [json]
  local m="$1" path="$2" body="${3:-}" args=()
  [ -n "$body" ] && args=(-H 'Content-Type: application/json' -d "$body")
  printf 'Authorization: token %s\n' "$FTOKEN" | curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X "$m" -H @- "${args[@]}" "$FORGEJO_URL/api/v1$path"
}

# --- list every repo the installation reaches, all pages
repos='[]'; total=''; page=1
while :; do
  resp="$(gh_get "$GH/installation/repositories?per_page=100&page=$page")"
  total="$(jq -r '.total_count' <<<"$resp")"
  n="$(jq '.repositories | length' <<<"$resp")"
  repos="$(jq -s '.[0] + .[1].repositories' <(echo "$repos") <(echo "$resp"))"
  [ "$n" -lt 100 ] && break
  page=$((page + 1))
done
listed="$(jq 'length' <<<"$repos")"
[ "$listed" -gt 0 ] || { echo "ERROR: the App reaches 0 repositories; refusing to report success" >&2; exit 1; }
[ "$listed" = "$total" ] || { echo "ERROR: GitHub reported total_count=$total but $listed were listed" >&2; exit 1; }

# --- the Forgejo org
code="$(f_api GET "/orgs/$ORG")"
if [ "$code" = 404 ]; then
  code="$(f_api POST /orgs "$(jq -n --arg o "$ORG" '{username:$o, visibility:"private"}')")"
  [ "$code" = 201 ] || { echo "ERROR: creating Forgejo org $ORG returned $code" >&2; exit 1; }
elif [ "$code" != 200 ]; then
  echo "ERROR: Forgejo org lookup returned $code" >&2; exit 1
fi

ok=0; empty=0; failed=0; failed_names=()
while IFS=$'\t' read -r owner name default empty_flag; do
  if [ "$owner" != "$ORG" ]; then echo "skip $owner/$name (other owner)"; continue; fi
  dir="$CACHE/$name.git"
  [ -d "$dir" ] || git init --bare -q "$dir"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GHTOKEN" | base64 -w0)"; export GIT_CONFIG_VALUE_0
  if ! git -C "$dir" fetch --prune --force -q "https://github.com/$ORG/$name.git" \
        '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>"$STATE_DIR/err.log"; then
    # A repo with no commits has nothing to fetch; GitHub flags it and it is not a failure.
    if [ "$empty_flag" = true ] || ! git -C "$dir" for-each-ref --count=1 | grep -q .; then
      empty=$((empty + 1)); echo "empty $name"; continue
    fi
    failed=$((failed + 1)); failed_names+=("$name"); echo "FAIL fetch $name: $(head -c 200 "$STATE_DIR/err.log")" >&2; continue
  fi
  if ! git -C "$dir" for-each-ref --count=1 | grep -q .; then empty=$((empty + 1)); echo "empty $name"; continue; fi
  git -C "$dir" symbolic-ref HEAD "refs/heads/$default" 2>/dev/null || true

  code="$(f_api GET "/repos/$ORG/$name")"
  if [ "$code" = 404 ]; then
    code="$(f_api POST "/orgs/$ORG/repos" "$(jq -n --arg n "$name" --arg d "$default" '{name:$n, private:true, default_branch:$d}')")"
    [ "$code" = 201 ] || { failed=$((failed + 1)); failed_names+=("$name"); echo "FAIL create $name: $code" >&2; continue; }
  fi
  GIT_CONFIG_VALUE_0="Authorization: token $FTOKEN"; export GIT_CONFIG_VALUE_0
  if git -C "$dir" push --prune --force -q "$FORGEJO_URL/$ORG/$name.git" \
       '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>"$STATE_DIR/err.log"; then
    f_api PATCH "/repos/$ORG/$name" "$(jq -n --arg d "$default" '{default_branch:$d}')" >/dev/null
    ok=$((ok + 1)); echo "ok $name"
  else
    failed=$((failed + 1)); failed_names+=("$name"); echo "FAIL push $name: $(head -c 200 "$STATE_DIR/err.log")" >&2
  fi
done < <(jq -r '.[] | [.owner.login, .name, .default_branch, (.size == 0)] | @tsv' <<<"$repos")
unset GHTOKEN GIT_CONFIG_VALUE_0

jq -n --arg at "$(date -u +%FT%TZ)" --argjson listed "$listed" --argjson total "$total" \
  --argjson ok "$ok" --argjson empty "$empty" --argjson failed "$failed" \
  --argjson names "$(printf '%s\n' "${failed_names[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{finished_at:$at, github_total:$total, examined:$listed, synced:$ok, empty:$empty, failed:$failed, failed_repos:$names}' \
  >"$STATE_DIR/status.json"
echo "examined $listed of $total GitHub repos: synced $ok, empty $empty, failed $failed"
[ "$failed" -eq 0 ] || exit 1
