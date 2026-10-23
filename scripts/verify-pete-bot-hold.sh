#!/usr/bin/env bash
# verify-pete-bot-hold.sh — prove pete-bot's maintenance-window hold on 237 (PET-492).
#
# WHAT IT PROVES. pete-bot (pete-bot#51, #55, #56) holds a DOWN that starts inside
# ALERT_MAINTENANCE_WINDOWS and releases it on the UP with no DM, and iac#509 renders that
# variable. This posts synthetic Kuma webhooks for a throwaway monitor and checks the answers:
#
#   1. /health carries a `held` field and reports 0, so the new binary runs and nothing is stuck.
#   2. A DOWN stamped inside the window answers `held`. That also proves the window is set.
#   3. The UP answers `released`.
#   4. A DOWN stamped outside the window answers `sent`, and its UP answers `edited`.
#      This one DMs Pedro once, for the monitor named below, and edits that DM green.
#   5. /health reports `held` 0 again.
#
# WHAT IT DOES NOT PROVE. A real backup night. While the Kuma window `pve03-nightly-backup`
# exists, Kuma sends pete-bot nothing for pve03's guests (PET-635), so the hold sees no real
# DOWN. After this passes, retire that window (a separate PR), then read one night's journal
# on 237: `journalctl -u pete-bot --since 02:40` should show `decision=held` and
# `decision=released` lines and no DMs.
#
# THE BEARER. Read from PETE_BOT_ALERT_TOKEN, or else from Vault through the workspace's
# scripts/pet-secrets. It is passed to curl on stdin and never printed or written down.
#
# Usage:
#   ./scripts/verify-pete-bot-hold.sh
#   PETE_BOT_URL=http://192.168.50.237:3015 ./scripts/verify-pete-bot-hold.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
URL="${PETE_BOT_URL:-http://192.168.50.237:3015}"
ZONE="${PETE_BOT_WINDOW_ZONE:-America/New_York}"
# Inside the 02:45 window and outside it, in the window's own zone, as the UTC strings Kuma sends.
IN_WINDOW="$(TZ=$ZONE date -d 'today 02:50' -u +'%Y-%m-%d %H:%M:%S')"
OUT_WINDOW="$(TZ=$ZONE date -d 'today 14:00' -u +'%Y-%m-%d %H:%M:%S')"
MONITOR="hold-proof-$(date +%s)"

fail(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
ok(){ printf '\033[1;32mok\033[0m   %s\n' "$*"; }

command -v jq >/dev/null || fail "jq is required"

TOKEN="${PETE_BOT_ALERT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  PET_SECRETS="${PET_SECRETS:-$REPO_ROOT/../scripts/pet-secrets}"
  [ -x "$PET_SECRETS" ] || fail "set PETE_BOT_ALERT_TOKEN, or put pet-secrets at $PET_SECRETS"
  TOKEN="$("$PET_SECRETS" get pete-bot alert_bearer_token)" || fail "pet-secrets could not read the alert bearer"
fi
[ -n "$TOKEN" ] || fail "the alert bearer is empty"

# post <heartbeat status> <heartbeat time>: prints the action pete-bot answered.
post(){
  local status="$1" when="$2" body reply
  body="$(jq -nc --arg m "$MONITOR" --arg t "$when" --argjson s "$status" \
    '{monitor:{name:$m},heartbeat:{status:$s,msg:"hold proof",time:$t}}')"
  reply="$(printf 'header = "authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS --max-time 15 -K - -H 'content-type: application/json' -d "$body" "$URL/v1/alert")" ||
    fail "POST /v1/alert did not complete"
  printf '%s' "$reply" | jq -er '.action' 2>/dev/null || fail "unexpected /v1/alert reply: $(printf '%s' "$reply" | head -c 200)"
}

held_count(){
  local reply
  reply="$(curl -sS --max-time 10 "$URL/health")" || fail "GET /health did not complete"
  printf '%s' "$reply" | jq -e '.held | numbers' 2>/dev/null || fail "/health has no numeric \`held\` field: the running pete-bot predates pete-bot#51, or ${URL} is not pete-bot"
}

expect(){
  local label="$1" want="$2" got="$3"
  case "$got" in
    "$want") ok "$label -> $got" ;;
    *) fail "$label: wanted \`$want\`, got \`$got\`" ;;
  esac
}

printf 'examining %s with monitor %s (in-window %s UTC, out-of-window %s UTC)\n' "$URL" "$MONITOR" "$IN_WINDOW" "$OUT_WINDOW"

expect "/health held before" 0 "$(held_count)"
expect "DOWN inside the window" held "$(post 0 "$IN_WINDOW")"
expect "/health held during the hold" 1 "$(held_count)"
expect "UP after the hold" released "$(post 1 "$IN_WINDOW")"
expect "DOWN outside the window" sent "$(post 0 "$OUT_WINDOW")"
expect "UP after the DM" edited "$(post 1 "$OUT_WINDOW")"
expect "/health held after" 0 "$(held_count)"

printf '\n\033[1;32mpassed\033[0m: 7 checks against %s. Next: retire the Kuma window, then read one night'"'"'s journal.\n' "$URL"
