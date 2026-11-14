#!/usr/bin/env bash
# lab-probe — run one read-only probe inside LXC 237 (pete-bot, lab-agent, mtrace) from the
# homelab runner (PET-878, PET-879; extends PET-861). A thread dispatches it through lab-action.yml
# instead of handing Pedro a prompt for the Mac.
#
#   scripts/lab-probe.sh journal <args>   # unit=lab-agent since=... until=... mode=callers|lines|count
#   scripts/lab-probe.sh mtrace  <args>   # title=<text>   -> mtrace trace_request, as caller lab-agent
#   scripts/lab-probe.sh media_ask <args> # question=<text> -> lab-agent POST /v1/media/ask
#   scripts/lab-probe.sh guests           # {"data":{"guests":[{vmid,node,status}]}} for scripts/check-staleness.py
#   scripts/lab-probe.sh backup_jobs      # the cluster's vzdump jobs: id, schedule, storage, mode, enabled (PET-884)
#   scripts/lab-probe.sh prometheus       # alert rules on metrics-240: metric-alerts rules, Prometheus rules, alerts, targets
#   scripts/lab-probe.sh ollama_ps        # models loaded in Ollama on CT 246: name, size, VRAM share, expiry
#   scripts/lab-probe.sh health [service=pete-bot|lab-agent]   # GET /health on 237; both when none is named
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

# guests needs no 237: it asks the first node that answers for the cluster's guest list and prints
# vmid, node and status only (no names, no addresses), as the vault staleness check reads it.
if [ "$PROBE" = guests ]; then
  [ -z "$ARGS" ] || die "guests takes no args"
  for n in 192.168.50.10 192.168.50.11 192.168.50.12; do
    if J="$(ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$n" 'pvesh get /cluster/resources --type vm --output-format json' 2>/dev/null)" && [ -n "$J" ]; then
      OUT="$(printf '%s' "$J" | python3 -c 'import json,sys; g=[{"vmid":r["vmid"],"node":r["node"],"status":r["status"]} for r in json.load(sys.stdin) if "vmid" in r]; print(json.dumps({"data":{"guests":g}}, separators=(",",":")))' 2>/dev/null)" || continue
      N="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["guests"]))')"
      [ "$N" -gt 0 ] || continue
      echo "$OUT"
      echo "probe guests: $N guests read from $n"
      exit 0
    fi
  done
  echo "FAILED: no node answered pvesh, so no guest was read." >&2; exit 1
fi

# backup_jobs asks the first node that answers for the cluster's vzdump jobs and prints, per job, the id,
# schedule, storage, mode, whether it is enabled, what it covers (a count of guests, or "all"), the node it
# is pinned to ("any" when none) and its excluded guests. It prints
# no comment text and no mail address. A cluster that holds 0 jobs is a valid answer and says so.
if [ "$PROBE" = backup_jobs ]; then
  [ -z "$ARGS" ] || die "backup_jobs takes no args"
  for n in 192.168.50.10 192.168.50.11 192.168.50.12; do
    if J="$(ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$n" 'pvesh get /cluster/backup --output-format json' 2>/dev/null)" && [ -n "$J" ]; then
      printf '%s' "$J" | python3 -c '
import json, sys
jobs = json.load(sys.stdin)
if not isinstance(jobs, list):
    sys.exit("not a list")
for j in jobs:
    cover = "all" if j.get("all") else str(len([v for v in str(j.get("vmid", "")).split(",") if v])) + " guests"
    # A job with no node runs on every node, so a stop-mode job with covers=all and node=any stops
    # every guest in the cluster (PET-635).
    print("job %s: schedule=%s storage=%s mode=%s enabled=%s covers=%s node=%s exclude=%s" % (
        j.get("id", "?"), j.get("schedule", j.get("starttime", "?")), j.get("storage", "?"),
        j.get("mode", "?"), "no" if str(j.get("enabled", 1)) == "0" else "yes", cover,
        j.get("node") or "any", j.get("exclude") or "none"))
print("probe backup_jobs: %d job(s) read from /cluster/backup" % len(jobs))
' || continue
      exit 0
    fi
  done
  echo "FAILED: no node answered pvesh for /cluster/backup, so no job was read." >&2; exit 1
fi

# ollama_ps asks Ollama on CT 246 which models it holds in memory (GET /api/ps) and prints, per model,
# the name, total size, the share in VRAM and when it unloads. It reaches the LAN directly from the
# runner, so it needs no 237 and no node. An empty list is a valid answer ("0 model(s) loaded"); an
# unreachable server or a body that is not the expected JSON fails.
if [ "$PROBE" = ollama_ps ]; then
  [ -z "$ARGS" ] || die "ollama_ps takes no args"
  J="$(curl -sS --fail -m 10 http://192.168.50.246:11434/api/ps 2>/dev/null)" \
    || { echo "FAILED: Ollama on 192.168.50.246:11434 did not answer /api/ps, so no model was read." >&2; exit 1; }
  printf '%s' "$J" | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d.get("models")
if not isinstance(m, list):
    sys.exit("FAILED: /api/ps returned no models list")
for x in m:
    size, vram = int(x.get("size", 0)), int(x.get("size_vram", 0))
    pct = "%d%%" % (100 * vram // size) if size else "?"
    print("model %s: size=%.1fGiB vram=%s expires=%s" % (str(x.get("name", "?"))[:80], size / 2**30, pct, str(x.get("expires_at", "?"))[:25]))
print("probe ollama_ps: %d model(s) loaded on CT 246" % len(m))
' || { echo "FAILED: /api/ps did not return the expected JSON." >&2; exit 1; }
  exit 0
fi

# prometheus reads the alert rules on metrics-240 (PET-914 read-back). Prometheus listens on 127.0.0.1 there,
# so the script finds the node that holds 240 and runs a fixed Python program inside it over `pct exec`.
# metric-alerts, not Prometheus, evaluates this lab's rules from /etc/metric-alerts/rules.json, so the
# probe prints both: those rules with the series each one returns now, Prometheus's own /api/v1/rules
# and /api/v1/alerts, and the target count. The caller supplies no value. It prints names, counts and
# health, never an expression's result labels beyond the metric name. A store that answers nothing or a
# rules file that does not parse fails.
REMOTE_PROM='import json, sys, urllib.parse, urllib.request
P = "http://127.0.0.1:9090"
def get(path, **q):
    u = P + path + ("?" + urllib.parse.urlencode(q) if q else "")
    with urllib.request.urlopen(u, timeout=15) as r:
        b = json.load(r)
    if b.get("status") != "success":
        sys.exit("FAILED: %s answered status %s" % (path, b.get("status")))
    return b["data"]
try:
    rules = json.load(open("/etc/metric-alerts/rules.json"))
except (OSError, ValueError) as e:
    sys.exit("FAILED: /etc/metric-alerts/rules.json did not read: %s" % e)
if not rules:
    sys.exit("FAILED: /etc/metric-alerts/rules.json holds no rules, so nothing was examined")
firing = 0
for r in rules:
    try:
        n = len(get("/api/v1/query", query=r["expr"])["result"])
        print("metric-alerts rule %s: in rules.json, for_runs=%s, %d series now" % (r["name"], r.get("for_runs", 1), n))
        firing += 1 if n else 0
    except Exception as e:
        print("metric-alerts rule %s: QUERY FAILED: %s" % (r["name"], str(e)[:120]))
        sys.exit("FAILED: the store did not answer for rule %s" % r["name"])
groups = get("/api/v1/rules")["groups"]
nrules = 0
for g in groups:
    for r in g["rules"]:
        nrules += 1
        print("prometheus rule %s/%s: type=%s health=%s state=%s" % (g["name"], r["name"], r["type"], r.get("health", "?"), r.get("state", "-")))
alerts = get("/api/v1/alerts")["alerts"]
for a in alerts:
    print("prometheus alert %s: %s" % (a["labels"].get("alertname", "?"), a["state"]))
t = get("/api/v1/targets", state="active")["activeTargets"]
if not t:
    sys.exit("FAILED: Prometheus lists no active targets, so the store is not scraping")
up = sum(1 for x in t if x["health"] == "up")
print("probe prometheus: read %d metric-alerts rules (%d with series now), %d Prometheus rules in %d groups, %d alerts, %d of %d targets up" % (len(rules), firing, nrules, len(groups), len(alerts), up, len(t)))'
if [ "$PROBE" = prometheus ]; then
  [ -z "$ARGS" ] || die "prometheus takes no args"
  PN=""
  for n in 192.168.50.10 192.168.50.11 192.168.50.12; do
    if ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$n" 'pct status 240' 2>/dev/null | grep -q 'status: running'; then PN="$n"; break; fi
  done
  [ -n "$PN" ] || { echo "FAILED: no node reports LXC 240 running, so nothing was examined." >&2; exit 1; }
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$PN" 'pct exec 240 -- python3 -c "$(cat)"' <<<"$REMOTE_PROM" \
    || { echo "FAILED: the Prometheus read on 240 failed, so no rule was confirmed." >&2; exit 1; }
  exit 0
fi

# Find the node that holds 237 now; guests move (PET-334).
NODE=""
for n in 192.168.50.10 192.168.50.11 192.168.50.12; do
  if ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$n" 'pct status 237' 2>/dev/null | grep -q 'status: running'; then NODE="$n"; break; fi
done
[ -n "$NODE" ] || { echo "FAILED: no node reports LXC 237 running, so nothing was examined." >&2; exit 1; }
in237() { ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$NODE" "pct exec 237 -- sh -c '$1'"; }

# 237 has no curl, so an HTTP call goes through bash's /dev/tcp. The script travels on stdin and
# takes the base64 body and the kind (mtrace or ask) as arguments, so no value is shell source.
# It reads the token from lab-agent.env as root, sends it only to its own socket, and prints the
# response body and a final "HTTP <code>" line.
REMOTE_POST='set -u
B="$1"; KIND="$2"; ENVF=/etc/lab-agent/lab-agent.env
get() { sed -n "s/^$1=//p" "$ENVF" | head -1; }
if [ "$KIND" = mtrace ]; then T=$(get LAB_MTRACE_TOKEN); U=$(get LAB_MTRACE_URL); U=${U:-http://192.168.50.237:8237}; P=/api/tool/trace_request
else T=$(get LAB_ASK_TOKEN); U=http://127.0.0.1:$(get LAB_PORT); U=${U%:}; P=/v1/media/ask; fi
case "$U" in http://127.0.0.1) U=http://127.0.0.1:3016 ;; esac
[ -n "$T" ] || { echo NO_TOKEN; exit 3; }
HP=${U#http://}; H=${HP%%:*}; PT=${HP##*:}
BODY=$(printf %s "$B" | base64 -d)
exec 3<>/dev/tcp/"$H"/"$PT" || exit 4
printf "POST %s HTTP/1.0\r\nHost: %s\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$P" "$H" "$T" "${#BODY}" "$BODY" >&3
RESP=$(timeout 120 cat <&3)
CODE=$(printf "%s" "$RESP" | head -1 | cut -d" " -f2)
printf "%s\n" "${RESP#*$'"'"'\r\n\r\n'"'"'}"
echo "HTTP $CODE"'
post237() { ssh -o ConnectTimeout=8 -o BatchMode=yes "$NODE" "pct exec 237 -- bash -s -- $1 $2" <<<"$REMOTE_POST"; }

# GET /health on a port of 237 itself. The script travels on stdin and takes only the port, which
# the caller never chooses. Prints the body, then a final "HTTP <code>" line.
REMOTE_GET='set -u
exec 3<>/dev/tcp/127.0.0.1/"$1" || { echo "HTTP none"; exit 4; }
printf "GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3
RESP=$(timeout 20 cat <&3)
CODE=$(printf "%s" "$RESP" | head -1 | cut -d" " -f2)
printf "%s\n" "${RESP#*$'"'"'\r\n\r\n'"'"'}"
echo "HTTP $CODE"'

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

  health)
    only service
    SVC="${KV[service]:-all}"
    [[ "$SVC" =~ ^(all|pete-bot|lab-agent)$ ]] || die "service must be pete-bot or lab-agent"
    # A fixed table: the caller names a service, never a port or a path.
    declare -A HPORT=([pete-bot]=3015 [lab-agent]=3016)
    TARGETS=(pete-bot lab-agent); [ "$SVC" = all ] || TARGETS=("$SVC")
    BAD=0
    for t in "${TARGETS[@]}"; do
      OUT="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$NODE" "pct exec 237 -- bash -s -- ${HPORT[$t]}" <<<"$REMOTE_GET")" \
        || OUT="HTTP none"
      CODE="$(printf '%s\n' "$OUT" | sed -n 's/^HTTP //p' | tail -1)"
      echo "--- $t /health: HTTP ${CODE:-none}"
      printf '%s\n' "$OUT" | grep -v '^HTTP ' | cut -c1-600
      [ "${CODE:-}" = 200 ] || BAD=$((BAD+1))
    done
    echo "probe health: read ${#TARGETS[@]} service(s) on 237, $BAD not HTTP 200"
    [ "$BAD" = 0 ] || exit 1 ;;

  mtrace)
    only title
    need title
    [[ "${KV[title]}" =~ ^[A-Za-z0-9\ :.,\&-]{1,80}$ ]] || die "title may hold letters, digits, space and : . , & - only, up to 80 characters"
    B64="$(printf '{"title":"%s"}' "${KV[title]}" | base64 -w0)"
    OUT="$(post237 "$B64" mtrace)" \
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
    OUT="$(post237 "$B64" ask)" \
      || { echo "FAILED: the media ask failed or lab-agent holds no ask token." >&2; exit 1; }
    printf '%s\n' "$OUT" | cut -c1-2000
    CODE="$(printf '%s\n' "$OUT" | sed -n 's/^HTTP //p' | tail -1)"
    echo "probe media_ask: one question answered HTTP ${CODE:-none}, ${#OUT} characters read"
    [ "${CODE:-}" = 200 ] || exit 1 ;;

  *) die "'$PROBE' is not a probe (journal, mtrace, media_ask, guests, health, backup_jobs, ollama_ps, prometheus)" ;;
esac
