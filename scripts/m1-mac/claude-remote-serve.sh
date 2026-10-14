#!/bin/bash
# claude-remote-serve.sh: the Mac's Remote Control server (PET-622), the macOS counterpart of
# the Pete-AI wrapper (PET-621) and claude-ops-pm-serve.j2 on LXC 247. The
# LaunchAgent dev.pdlab.claude-remote runs an installed copy at login. install-claude-remote.sh
# installs both, and docs/runbooks/m1-mac-remote-control.md covers setup, stop and logs.
#
#   claude-remote-serve.sh            serve
#   claude-remote-serve.sh --check    run the preflight checks only, then exit
#
# Written for /bin/bash 3.2, the bash macOS ships. Logs go to ~/Library/Logs/claude-remote/:
# serve.log (this script), run-resume.log and run-fresh.log (the CLI's output) and
# claude-debug.log (the CLI's debug file).
#
# FAIL LOUDLY BEFORE STARTING. A server with no terminal hangs on any interactive prompt (247
# hung for two days on 2026-09-12). So this script refuses to start, with a non-zero exit and a
# line in serve.log, until the Remote Control consent and the folder's trust prompt are answered
# by hand. It never answers them itself.
#
# RESUME FIRST, THEN START FRESH. `remote-control --continue` reattaches to the session this
# folder last recorded, but only within roughly 4 hours. With nothing to resume, it prints "No
# recent session found" and exits 1 (measured on 247, 2026-10-14). Its exit code is not
# trusted, so any exit of the resume attempt starts a fresh server.
#
# WAIT ON THE SERVER'S PID ALONE. Each CLI run starts in the background and `wait` takes its
# pid, so a session child that outlives the server can't hold the loop.
#
# STOP A DEAD SERVER'S SESSIONS. Each server runs in its own process group. When it exits, the
# session processes it spawned (`claude --print --sdk-url ...`) can outlive it, and the next
# server's --continue would reattach their session beside them. So this script logs each
# survivor in that group, sends it SIGTERM, and then SIGKILL after 5 seconds. A turn in flight
# is lost. The log names each survivor by pid and executable name only, because a session's
# command line can carry a token. The group is the boundary: a pattern such as `--sdk-url`
# would also match the desktop app's and the terminal's sessions. On a stop, launchd sends
# SIGTERM to this script, and the trap passes it to the whole group. Never start the server
# with setsid or nohup, which would move it out of that group.
#
# BOUNDED RESTART, AND A GIVE-UP THAT STAYS VISIBLE. An expired login makes the CLI exit at
# once. Five cycles within five minutes end this script with exit 5. The LaunchAgent sets
# KeepAlive to false, so launchd doesn't restart it. The give-up writes to serve.log, shows a
# macOS notification and sends Pedro a pete-bot DM.
#
# STAY AWAKE WHILE SERVING. `caffeinate -s -w <this pid>` holds off system sleep on AC power
# for as long as this script runs. Closing the lid still sleeps the Mac.
#
# Every setting can be overridden from the environment, which is how the tests stub the CLI.
set -u

workdir="${CLAUDE_REMOTE_WORKDIR:-$HOME/petedio}"
prefix="${CLAUDE_REMOTE_PREFIX:-Mac}"
mode="${CLAUDE_REMOTE_PERMISSION_MODE:-auto}"
spawn="${CLAUDE_REMOTE_SPAWN:-worktree}"
claude="${CLAUDE_REMOTE_CLI:-$HOME/.local/bin/claude}"
config="${CLAUDE_REMOTE_CONFIG:-$HOME/.claude.json}"
logdir="${CLAUDE_REMOTE_LOGDIR:-$HOME/Library/Logs/claude-remote}"
pet_secrets="${CLAUDE_REMOTE_PET_SECRETS:-$HOME/petedio/scripts/pet-secrets}"
notify_url="${CLAUDE_REMOTE_NOTIFY_URL:-http://192.168.50.237:3015/v1/notify}"
dns_wait_s="${CLAUDE_REMOTE_DNS_WAIT_S:-600}"
cycle_pause_s="${CLAUDE_REMOTE_CYCLE_PAUSE_S:-30}"
max_exits=5
window_s=300
jq=/usr/bin/jq

mkdir -p "$logdir"
log="$logdir/serve.log"

say() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$log"; }

# Best effort, and never fatal: a give-up that can't send its DM must still exit 5.
alert() {
  osascript -e "display notification \"$1\" with title \"Mac Remote Control\"" >/dev/null 2>&1 || true
  local tok
  tok="$("$pet_secrets" get pete-bot notify_bearer_token 2>/dev/null)" || tok=""
  if [ -z "$tok" ]; then
    say "ALERT not sent to pete-bot: no notify token (is Vault sealed?)."
    return 0
  fi
  # shellcheck disable=SC2016 # $m is a jq variable, not a shell one.
  if "$jq" -n --arg m "$1" '{from: "Mac Remote Control", message: $m}' \
      | curl -sS -m 10 -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
          --data-binary @- "$notify_url" 2>>"$log" | grep -q messageId; then
    say "ALERT sent to pete-bot."
  else
    say "ALERT not confirmed by pete-bot: no messageId in its reply."
  fi
}

fail() {
  say "FAIL (exit $1): $2"
  printf 'claude-remote-serve: %s\n' "$2" >&2
  exit "$1"
}

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

say "Starting: workdir=$workdir prefix=$prefix mode=$mode spawn=$spawn check_only=$check_only"

# Preflight. Each check names what it read, so "not found" and "not checked" can't look alike.
[ -x "$jq" ] || fail 1 "no jq at $jq"
[ -x "$claude" ] || fail 1 "no Claude CLI at $claude"
[ -d "$workdir" ] || fail 1 "no working folder at $workdir"
[ -f "$config" ] || fail 2 "no $config. Sign in to the Claude CLI first."
"$jq" -e '.remoteDialogSeen == true' "$config" >/dev/null 2>&1 \
  || fail 2 "$config has no remoteDialogSeen. To answer the consent prompt, run 'claude remote-control' by hand in $workdir, answer y, then press Ctrl+C."
# shellcheck disable=SC2016 # $k is a jq variable, not a shell one.
"$jq" -e --arg k "$workdir" '.projects[$k].hasTrustDialogAccepted == true' "$config" >/dev/null 2>&1 \
  || fail 3 "$config does not trust $workdir. To trust it, run 'claude' by hand in $workdir and accept the trust prompt."

# One server per user. The match is the `remote-control` subcommand after a CLI path, so an
# interactive session's `--remote-control` flag and the desktop app don't count.
running="$(pgrep -u "$(id -u)" -f 'claude[^ ]* remote-control( |$)' | tr '\n' ' ')"
if [ -n "$running" ]; then
  say "A Remote Control server already runs (pid $running). Exiting."
  exit 0
fi

if $check_only; then
  say "Preflight passed (--check)."
  echo "claude-remote-serve: preflight passed."
  exit 0
fi

# Wait for DNS, so a network that comes up after login doesn't fail the agent.
deadline=$(( $(date +%s) + dns_wait_s ))
until dscacheutil -q host -a name api.anthropic.com | grep -q 'ip.*_address'; do
  [ "$(date +%s)" -lt "$deadline" ] || fail 4 "api.anthropic.com did not resolve within $dns_wait_s seconds"
  sleep 10
done

caffeinate -s -w $$ &

# Every flag goes AFTER `remote-control`: a global flag before it stops the CLI from starting.
flags=(--permission-mode "$mode" --remote-control-session-name-prefix "$prefix" --debug-file "$logdir/claude-debug.log")

pid=""

# stop_all: on launchd's SIGTERM, stop the server's whole group, and SIGKILL it after 10
# seconds. launchd's own group kill can't reach a server in its own group, and it SIGKILLs this
# script after ExitTimeOut (30 s), so a server that ignores SIGTERM must not hold the trap.
stop_all() {
  say "Stopping on a signal."
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null
    local i=0
    while pgrep -g "$pid" >/dev/null && [ "$i" -lt 10 ]; do
      sleep 1
      i=$((i + 1))
    done
    if pgrep -g "$pid" >/dev/null; then
      say "The server's group ignored SIGTERM. Sending SIGKILL to process group $pid."
      kill -KILL -- "-$pid" 2>/dev/null
    fi
  fi
  exit 143
}
trap stop_all TERM INT

# reap <pgid>: stop whatever is left in a dead server's process group, and log each process.
reap() {
  local left
  left="$(pgrep -g "$1")" || return 0
  for p in $left; do
    say "A survivor of the server outlives it: pid $p, $(ps -o ucomm= -p "$p")"
  done
  kill -TERM -- "-$1" 2>/dev/null
  sleep 5
  if pgrep -g "$1" >/dev/null; then
    say "Survivors ignored SIGTERM. Sending SIGKILL to process group $1."
    kill -KILL -- "-$1" 2>/dev/null
  fi
}

# run <label> <args...>: run the CLI in the folder with no input, in its own process group,
# wait on its pid alone, set rc, then reap the group.
run() {
  local label="$1"
  shift
  set -m
  (cd "$workdir" && exec "$claude" remote-control "$@" "${flags[@]}") </dev/null >"$logdir/run-$label.log" 2>&1 &
  pid=$!
  set +m
  wait "$pid"
  rc=$?
  reap "$pid"
  pid=""
}

exits=""
while :; do
  say "Resume attempt: remote-control --continue"
  run resume --continue
  say "The resume attempt ended (exit $rc). Starting a fresh server."

  run fresh --spawn "$spawn"
  say "The fresh server ended (exit $rc)."

  # One exit per cycle, counted after the fresh server ends, inside a sliding window.
  now=$(date +%s)
  kept=""
  for t in $exits $now; do
    [ "$t" -ge $((now - window_s)) ] && kept="$kept $t"
  done
  exits="$kept"
  # shellcheck disable=SC2086 # split on purpose: one word per exit time.
  set -- $exits
  if [ $# -ge $max_exits ]; then
    msg="The Mac's Remote Control server exited $max_exits times in $((window_s / 60)) minutes and stopped. Read ~/Library/Logs/claude-remote/run-fresh.log; an expired login is the usual cause."
    alert "$msg"
    fail 5 "$msg"
  fi
  sleep "$cycle_pause_s"
done
