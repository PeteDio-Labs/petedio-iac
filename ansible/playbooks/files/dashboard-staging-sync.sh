#!/usr/bin/env bash
# dashboard-staging-sync — publish the lab dashboard's fixtures-only build to Caddy's :8081 site.
#
# Runs as root from dashboard-staging-sync.timer, once a minute. It reads a public release asset
# that pete-bot's CI builds, so the host holds no credential and builds no branch code. It checks
# the asset's SHA-256 against the sibling .sha256 file, unpacks into a new release directory,
# and moves /srv/dashboard-staging/current to it in one rename. A failed run leaves the previous
# release live and exits non-zero.
#
# status.json says what was examined: the checksum it read, the checksum that is live, and the
# result of the last run. Caddy serves it at /__staging.json.
set -euo pipefail

BASE_URL="https://github.com/petedio-labs/pete-bot/releases/download/dashboard-staging"
ASSET="dashboard-dist.tar.gz"
BASE=/srv/dashboard-staging
STATUS="$BASE/status.json"

exec 9>/run/dashboard-staging-sync.lock
flock -w 300 9 || { echo "dashboard-staging-sync: another sync held the lock for 300 s." >&2; exit 1; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
live_sum() { [ -f "$BASE/live-sha256" ] && cat "$BASE/live-sha256" || printf none; }

write_status() {
  jq -n --arg result "$1" --arg sum "$2" --arg detail "$3" --arg live "$(live_sum)" --arg at "$(now)" \
    '{checked_at:$at, source:"pete-bot release dashboard-staging", asset_sha256:$sum, live_sha256:$live, result:$result, detail:$detail}' \
    > "$STATUS.new"
  chmod 0644 "$STATUS.new"
  mv "$STATUS.new" "$STATUS"
}

sum=""
work=""
trap 'if [ -n "$work" ]; then rm -rf "$work"; fi' EXIT
fail() {
  echo "dashboard-staging-sync: FAILED: $1" >&2
  write_status failed "$sum" "$1"
  exit 1
}

sum=$(curl -fsSL --max-time 30 "$BASE_URL/$ASSET.sha256" | awk '{print $1; exit}') \
  || fail "could not read $ASSET.sha256 from the release."
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { fail "the .sha256 file held no SHA-256 (read: ${sum:0:20})."; }

if [ "$sum" = "$(live_sum)" ]; then
  write_status current "$sum" "release matches the live build; nothing to do"
  echo "dashboard-staging-sync: live build already matches ${sum:0:12}."
  exit 0
fi

work=$(mktemp -d /var/lib/dashboard-staging-build.XXXXXX)
curl -fsSL --max-time 120 -o "$work/$ASSET" "$BASE_URL/$ASSET" || fail "could not download $ASSET."
got=$(sha256sum "$work/$ASSET" | awk '{print $1}')
[ "$got" = "$sum" ] || fail "checksum mismatch: asset $got, expected $sum."

rel="$BASE/releases/$sum"
rm -rf "$rel"
mkdir -p "$rel"
# GNU tar refuses absolute names and `..` members. --no-same-owner keeps files owned by root.
tar -xzf "$work/$ASSET" -C "$rel" --no-same-owner || fail "could not unpack $ASSET."
[ -s "$rel/index.html" ] || fail "the unpacked build has no index.html."

ln -sfn "$rel" "$BASE/current.new"
mv -T "$BASE/current.new" "$BASE/current"
printf '%s' "$sum" > "$BASE/live-sha256"
# Keep the live release and the previous one.
ls -1dt "$BASE"/releases/*/ | tail -n +4 | xargs -r rm -rf
write_status published "$sum" "published $(find "$rel" -type f | wc -l) files"
echo "dashboard-staging-sync: published ${sum:0:12}."
