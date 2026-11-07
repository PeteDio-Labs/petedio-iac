#!/usr/bin/env bash
# lab-probe — run one read-only probe inside LXC 237 (pete-bot, lab-agent, mtrace) from the
# homelab runner (PET-878, PET-879; extends PET-861). A thread dispatches it through lab-action.yml
# instead of handing Pedro a prompt for the Mac.
#
#   scripts/lab-probe.sh journal <args>   # unit=lab-agent since=... until=... mode=callers|lines|count
#   scripts/lab-probe.sh mtrace  <args>   # title=<text>   -> mtrace trace_request, as caller lab-agent
#   scripts/lab-probe.sh media_ask <args> # question=<text> -> lab-agent POST /v1/media/ask
#
# WHAT RUNS. Each probe is a fixed command. The caller supplies values, never commands: every value
# must match a strict pattern below, and the remote text carries only base64 or an allowlisted
# word, so no value reaches a shell as code.
#
# CREDENTIALS. None is placed. `mtrace` and `media_ask` read lab-agent's own mtrace token and ask
# port from /etc/lab-agent/lab-agent.env inside 237, as root, in one remote command. The token
# never leaves 237 and never reaches this script's output. The caller shows in mtrace's journal as
# `lab-agent`, which is the same caller the media assistant uses.
#
# WHAT IT PRINTS. The run log is public. `journal` prints counts and distinct `caller=` values by
# default; `lines` prints only lines matching a fixed phrase, cut to 300 characters. `mtrace` and
# `media_ask` print the reply, cut to 2000 characters, which names the titles in it. The last line
# is a summary that says what was examined, so an empty window reads as `0 lines`, never as a pass.
#
# Needs the SSH setup lab-action.sh builds: the `ssh` wrapper first on PATH, the node aliases, and
# the pinned host keys. Run it through lab-action.sh, not by hand.
set -euo pipefail

PROBE="${1:-}"
ARGS="${2:-}"

die() { echo "REFUSED: $*" >&2; exit 2; }

# key=value pairs, space separated. Values may hold spaces only for title and question.
declare -A KV=()
parse() {
  local s="$ARGS" key val
  while [ -n "$s" ]; do
    s="${s#"${s%%[![:space:]]*}"}"
    [ -n "$s" ] || break
    key="${s%%=*}"
    [[ "$s" == *=* && "$key" =~ ^[a-z]+$ ]] || die "args must be key=value pairs, got '${s:0:40}'"
    s="${s#*=}"
    if [[ "$key" == title || "$key" == question ]]; then
      val="$s"; s=""   # the text runs to the end, so put it last
    else
      val="${s%%[[:space:]]*}"; s="${s#"$val"}"
    fi
    KV[$key]="$val"
  done
}
parse
need() { [ -n "${KV[$1]:-}" ] || die "$PROBE needs $1=..."; }
only() { local k; for k in "${!KV[@]}"; do [[ " $* " == *" $k "* ]] || die "$PROBE takes no '$k'"; done; }

# Find the node that holds 237 now; guests move (PET-334).
NODE=""
for n in 192.168.50.10 192.168.50.11 192.168.50.12; do
  if ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$n" 'pct status 237' 2>/dev/null | grep -q 'status: running'; then NODE="$n"; break; fi
done
[ -n "$NODE" ] || { echo "FAILED: no node reports LXC 237 running, so nothing was examined." >&2; exit 1; }
in237() { ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$NODE" "pct exec 237 -- sh -c '$1'"; }

TS='^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]$'

case "$PROBE" in
  journal)
    only unit since until mode
    need unit; need since; need until
    [[ "${KV[unit]}" =~ ^(mtrace|pete-bot|lab-agent)$ ]] || die "unit must be mtrace, pete-bot or lab-agent"
    [[ "${KV[since]}" =~ $TS && "${KV[until]}" =~ $TS ]] || die "since and until must look like 2026-11-07T08:12:00 (UTC)"
    MODE="${KV[mode]:-count}"
    [[ "$MODE" =~ ^(callers|lines|count)$ ]] || die "mode must be callers, lines or count"
    S="${KV[since]/T/ }"; U="${KV[until]/T/ }"
    TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
    in237 "journalctl -u ${KV[unit]} --since \"$S\" --until \"$U\" --utc --no-pager -o cat" > "$TMP" 2>/dev/null \
      || { echo "FAILED: journalctl on 237 failed, so nothing was examined." >&2; exit 1; }
    N="$(wc -l < "$TMP")"
    case "$MODE" in
      callers)
        echo "caller values in ${KV[unit]} from $S to $U UTC (count of lines each):"
        grep -oE 'caller=[A-Za-z0-9_-]{1,40}' "$TMP" | sort | uniq -c | sort -rn || true
        C="$(grep -cE 'caller=' "$TMP" || true)"
        echo "probe journal: read $N lines, $C carry caller=" ;;
      lines)
        grep -E 'media ask answered|media ask failed|media act (done|failed)' "$TMP" | cut -c1-300 || true
        C="$(grep -cE 'media ask answered|media ask failed|media act (done|failed)' "$TMP" || true)"
        echo "probe journal: read $N lines, $C match a media ask or act phrase" ;;
      count) echo "probe journal: read $N lines of ${KV[unit]} from $S to $U UTC" ;;
    esac
    [ "$N" -gt 0 ] || { echo "FAILED: the window held 0 lines, so nothing was examined." >&2; exit 1; } ;;

  mtrace)
    only title
    need title
    [[ "${KV[title]}" =~ ^[A-Za-z0-9\ :.,\&-]{1,80}$ ]] || die "title may hold letters, digits, space and : . , & - only, up to 80 characters"
    B64="$(printf '{"title":"%s"}' "${KV[title]}" | base64 -w0)"
    OUT="$(in237 "T=\$(sed -n \"s/^LAB_MTRACE_TOKEN=//p\" /etc/lab-agent/lab-agent.env); U=\$(sed -n \"s/^LAB_MTRACE_URL=//p\" /etc/lab-agent/lab-agent.env); [ -n \"\$T\" ] || { echo NO_TOKEN; exit 3; }; echo $B64 | base64 -d | curl -sS -m 30 -w \"\\nHTTP %{http_code}\\n\" -H \"Authorization: Bearer \$T\" -H \"Content-Type: application/json\" --data @- \"\${U:-http://192.168.50.237:8237}/api/tool/trace_request\"")" \
      || { echo "FAILED: the mtrace call failed or lab-agent holds no mtrace token." >&2; exit 1; }
    printf '%s\n' "$OUT" | cut -c1-2000
    CODE="$(printf '%s\n' "$OUT" | sed -n 's/^HTTP //p' | tail -1)"
    echo "probe mtrace: trace_request for '${KV[title]}' answered HTTP ${CODE:-none}, ${#OUT} characters read"
    [ "${CODE:-}" = 200 ] || exit 1 ;;

  media_ask)
    only question
    need question
    [[ "${KV[question]}" =~ ^[A-Za-z0-9\ :.,\&?\'-]{2,300}$ ]] || die "question may hold letters, digits, space and : . , & ? ' - only, 2 to 300 characters"
    B64="$(python3 -c 'import json,sys; print(json.dumps({"question": sys.argv[1]}))' "${KV[question]}" | base64 -w0)"
    OUT="$(in237 "T=\$(sed -n \"s/^LAB_ASK_TOKEN=//p\" /etc/lab-agent/lab-agent.env); P=\$(sed -n \"s/^LAB_PORT=//p\" /etc/lab-agent/lab-agent.env); [ -n \"\$T\" ] || { echo NO_TOKEN; exit 3; }; echo $B64 | base64 -d | curl -sS -m 120 -w \"\\nHTTP %{http_code}\\n\" -H \"Authorization: Bearer \$T\" -H \"Content-Type: application/json\" --data @- \"http://127.0.0.1:\${P:-3016}/v1/media/ask\"")" \
      || { echo "FAILED: the media ask failed or lab-agent holds no ask token." >&2; exit 1; }
    printf '%s\n' "$OUT" | cut -c1-2000
    CODE="$(printf '%s\n' "$OUT" | sed -n 's/^HTTP //p' | tail -1)"
    echo "probe media_ask: one question answered HTTP ${CODE:-none}, ${#OUT} characters read"
    [ "${CODE:-}" = 200 ] || exit 1 ;;

  *) die "'$PROBE' is not a probe (journal, mtrace, media_ask)" ;;
esac
