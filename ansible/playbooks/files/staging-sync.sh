#!/usr/bin/env bash
# staging-sync — build the portfolio's `staging` branch and publish it to Caddy's site root.
#
# Runs as root from staging-sync.timer, once a minute. It mints a one-hour, read-only GitHub App
# token for pdlabs-portfolio, reads the branch tip, and stops when that commit is already live.
# Otherwise it clones the branch, builds it as the unprivileged `staging` user, and moves
# /srv/staging/current to the new release in one rename. A failed build leaves the previous
# release live and exits non-zero.
#
# status.json says what was examined: the branch tip it read, the commit that is live, and the
# result of the last run. Caddy serves it at /__staging.json.
set -euo pipefail

REPO="petedio-labs/pdlabs-portfolio"
BRANCH="staging"
BASE=/srv/staging
STATUS="$BASE/status.json"
ENV_FILE=/etc/staging/app.env
PEM=/etc/staging/app.pem
BUILD_USER=staging

# One sync at a time, whether the timer or a deploy started it. A second run waits for the first.
exec 9>/run/staging-sync.lock
flock -w 900 9 || { echo "staging-sync: another sync held the lock for 900 s." >&2; exit 1; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
live_sha() { [ -f "$BASE/live-sha" ] && cat "$BASE/live-sha" || printf none; }

# write_status <result> <tip> <detail>
write_status() {
  jq -n --arg result "$1" --arg tip "$2" --arg detail "$3" --arg live "$(live_sha)" --arg at "$(now)" \
    --arg branch "$BRANCH" --arg repo "$REPO" \
    '{checked_at:$at, repo:$repo, branch:$branch, branch_tip:$tip, live_sha:$live, result:$result, detail:$detail}' \
    > "$STATUS.new"
  chmod 0644 "$STATUS.new"
  mv "$STATUS.new" "$STATUS"
}

tip=""
work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT
fail() {
  echo "staging-sync: FAILED: $1" >&2
  write_status failed "$tip" "$1"
  exit 1
}

for f in "$ENV_FILE" "$PEM"; do
  [ -s "$f" ] || fail "$f is missing. Run the deploy-staging-249 workflow."
done
# shellcheck disable=SC1090
. "$ENV_FILE"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
iat=$(( $(date +%s) - 30 ))
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$(( iat + 540 ))" "$APP_ID" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$PEM" | b64url) \
  || fail "could not sign the App JWT with $PEM"
jwt="$header.$payload.$sig"

# The JWT goes to curl on stdin (-H @-), through the shell builtin printf, so it never appears in
# an argument list that the build user could read from /proc.
resp=$(printf 'Authorization: Bearer %s\n' "$jwt" | curl -fsS --max-time 30 -X POST \
  -H @- -H "Accept: application/vnd.github+json" \
  -d '{"repositories":["pdlabs-portfolio"],"permissions":{"contents":"read"}}' \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens") \
  || fail "GitHub refused the installation token. Check that the App is installed on pdlabs-portfolio with contents read."
token=$(printf '%s' "$resp" | jq -er .token) || fail "GitHub's token reply held no token."

# The token goes in the environment, never in an argument or a file.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=http.extraheader
export GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)"
export GIT_TERMINAL_PROMPT=0
url="https://github.com/$REPO.git"

ls_out=$(git ls-remote "$url" "refs/heads/$BRANCH") || fail "git ls-remote failed for $REPO"
tip=$(printf '%s' "$ls_out" | cut -f1)
if [ -z "$tip" ]; then
  echo "staging-sync: $REPO has no $BRANCH branch yet; nothing to build."
  write_status no-branch "" "$REPO has no $BRANCH branch"
  exit 0
fi

if [ "$tip" = "$(live_sha)" ]; then
  echo "staging-sync: unchanged. $BRANCH tip $tip is live."
  write_status unchanged "$tip" "live matches the branch tip"
  exit 0
fi

echo "staging-sync: $BRANCH moved to $tip (live $(live_sha)). Building."
work=$(mktemp -d /var/lib/staging-build/work.XXXXXX)
git clone -q --depth 1 --branch "$BRANCH" "$url" "$work/src" || fail "git clone failed"
cloned=$(git -C "$work/src" rev-parse HEAD)
[ "$cloned" = "$tip" ] || tip="$cloned"
# The token has done its work. Drop it before any branch code runs.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 token resp jwt
rm -rf "$work/src/.git"
chown -R "$BUILD_USER:$BUILD_USER" "$work"

# Branch code runs only here, as an unprivileged user with no access to the App key.
runuser -u "$BUILD_USER" -- env -i HOME="$work/home" PATH=/usr/local/bin:/usr/bin:/bin \
  bash -c 'mkdir -p "$HOME" && cd "$1/src" && bun install --frozen-lockfile && bun run build' _ "$work" \
  || fail "bun install or bun run build failed for $tip"

# Stop everything the build left behind before root reads its output. Only builds run as this
# user, and the lock keeps them one at a time, so killing the user's processes is safe. A leftover
# process could otherwise swap dist/ for a symlink after the checks below.
pkill -KILL -u "$BUILD_USER" || true
sleep 1
if pgrep -u "$BUILD_USER" >/dev/null; then fail "build processes survived the kill"; fi

dist="$work/src/dist"
[ -d "$dist" ] && [ ! -L "$dist" ] || fail "dist is missing or is a symlink"
[ -f "$dist/index.html" ] || fail "the build produced no dist/index.html"
if [ -n "$(find "$dist" -type l -print -quit)" ]; then fail "dist holds a symlink, which a published site never needs"; fi

# Take the output into a root-owned copy, then check the copy, so nothing the build user can still
# reach is read or changed as root.
rel="$BASE/releases/$tip"
tmp_rel="$BASE/releases/.new-$$"
rm -rf "$tmp_rel"
cp -a --no-dereference "$dist" "$tmp_rel"
chown -R root:root "$tmp_rel"
if [ -n "$(find "$tmp_rel" -type l -print -quit)" ]; then rm -rf "$tmp_rel"; fail "the copied release holds a symlink"; fi
count=$(find "$tmp_rel" -type f | wc -l)
chmod -R a+rX "$tmp_rel"
rm -rf "$rel"
mv "$tmp_rel" "$rel"
ln -sfn "$rel" "$BASE/current.new"
mv -T "$BASE/current.new" "$BASE/current"
printf '%s' "$tip" > "$BASE/live-sha"

# Keep the three newest releases.
ls -1dt "$BASE"/releases/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf

echo "staging-sync: published $tip ($count files)."
write_status published "$tip" "built and published $count files"
