#!/usr/bin/env python3
"""metric-alerts: evaluate PromQL rules against the metrics store and post state changes to the
Lab-Agent DM. Managed by Ansible: roles/metric-alerts (PET-708).

Each rule is a PromQL query that returns a series for every offender and nothing when all is well,
for example `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.08`. A series that
appears in `for_runs` runs in a row posts FIRING once. A series that disappears after a post
posts RESOLVED once. Each state marker follows its own post's result, so a failed post retries on
the next run and a post that never arrived cannot read as sent.

A store that answers nothing is not a quiet lab. The script checks each query's HTTP status, and a
rule named `coverage` counts the live node targets, so an empty store pages instead of reading as
"0 offenders". A failed query or post exits non-zero, so the unit shows it.

  metric-alerts            evaluate, post on a state change
  metric-alerts --check    evaluate and print, post nothing, change no state
  metric-alerts --test     post one test line to prove the bot token and the DM
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PROM = os.environ.get("METRIC_ALERTS_PROM", "http://127.0.0.1:9090")
RULES = os.environ.get("METRIC_ALERTS_RULES", "/etc/metric-alerts/rules.json")
STATE = os.environ.get("METRIC_ALERTS_STATE", "/var/lib/metric-alerts/state.json")
DISCORD_CURL = os.environ.get("METRIC_ALERTS_DISCORD", "/etc/metric-alerts/discord.curl")
HOST = os.uname().nodename
# Every alert is also an event on one Loki stream (job=events). The event ID is a hash of the
# rule, the offender and the incident start, so a retry or a copy on the other side carries the same
# ID and Loki drops the repeat (PET alert-router, streams design).
LOKI = os.environ.get("METRIC_ALERTS_LOKI", "http://127.0.0.1:3100")
ENV = os.environ.get("METRIC_ALERTS_ENV", "lab")
# A series whose host label matches this is a Lab Villains decoy: it becomes an event and never a DM.
DECOY = re.compile(os.environ.get("METRIC_ALERTS_DECOY_HOST", r"^decoy-"))


def query(expr):
    """Return the instant-vector result for expr, or raise when the store did not answer."""
    url = "%s/api/v1/query?%s" % (PROM, urllib.parse.urlencode({"query": expr}))
    with urllib.request.urlopen(url, timeout=15) as resp:
        body = json.load(resp)
    if body.get("status") != "success":
        raise RuntimeError("query failed: %s" % body)
    return body["data"]["result"]


def post(text):
    """Post one message through curl, which reads the channel URL and the token from a config file."""
    cmd = ["curl", "-sS", "-f", "-m", "10", "-o", "/dev/null", "-K", DISCORD_CURL,
           "-H", "Content-Type: application/json", "-d", json.dumps({"content": text})]
    return subprocess.run(cmd, check=False).returncode == 0


def event_id(key, since):
    """One ID per incident: the same rule, offender and start always give the same ID."""
    return hashlib.sha256(("%s@%d" % (key, since)).encode()).hexdigest()[:16]


def push_event(kind, rule, key, metric, since, ts):
    """Append one JSON event to Loki. The line and its timestamp repeat exactly on a retry."""
    line = json.dumps({"event_id": event_id(key, since), "kind": kind, "rule": rule["name"],
                       "key": key, "host": metric.get("host", ""), "since": since, "env": ENV,
                       "source": "metric-alerts"}, sort_keys=True)
    labels = {"job": "events", "kind": kind, "source": "metric-alerts", "env": ENV}
    body = {"streams": [{"stream": labels, "values": [[str(int(ts * 1e9)), line]]}]}
    req = urllib.request.Request(LOKI + "/loki/api/v1/push", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10):
            return True
    except Exception:  # noqa: BLE001 - a failed push retries on the next run
        return False


def is_decoy(metric):
    return bool(DECOY.search(metric.get("host", "")))


def label_key(rule, metric):
    labels = ",".join("%s=%s" % (k, metric[k]) for k in sorted(metric) if k not in ("__name__", "job", "instance"))
    return "%s{%s}" % (rule, labels)


def describe(rule, series):
    labels = ", ".join("%s=%s" % (k, v) for k, v in sorted(series["metric"].items())
                       if k not in ("__name__", "job", "instance"))
    return "%s (%s) value %s" % (rule["summary"], labels or "no labels", series["value"][1][:8])


def evaluate(rules, state, query_fn=query, post_fn=post, mode="run", event_fn=push_event, now=time.time):
    """Run every rule once. Returns (exit_code, lines_printed)."""
    rc, lines = 0, []
    new_state = {}
    failed = 0
    for rule in rules:
        try:
            result = query_fn(rule["expr"])
        except Exception as err:  # noqa: BLE001 - any failure to read the store is a failed run
            lines.append("rule %s: QUERY FAILED: %s" % (rule["name"], err))
            rc = 1
            failed += 1
            # Keep this rule's counters as they were: a failed read proves nothing either way.
            for key, val in state.items():
                if key.startswith(rule["name"] + "{"):
                    new_state[key] = val
            continue
        seen = set()
        for series in result:
            key = label_key(rule["name"], series["metric"])
            seen.add(key)
            prev = state.get(key, {"runs": 0, "posted": False})
            runs, posted = prev["runs"] + 1, prev["posted"]
            since = prev.get("since") or int(now())
            logged = prev.get("logged", False)
            decoy = is_decoy(series["metric"])
            lines.append("rule %s: %s FIRING run %d%s" % (rule["name"], key, runs, " (decoy)" if decoy else ""))
            if mode == "run" and runs >= rule.get("for_runs", 1):
                if not logged:
                    if event_fn("alert.firing", rule, key, series["metric"], since, since):
                        logged = True
                    else:
                        rc = 1
                # A decoy never pages: the event is the record, and the scorecard reads it.
                if not posted:
                    if decoy:
                        posted = True
                    elif post_fn("FIRING: %s. From %s." % (describe(rule, series), HOST)):
                        posted = True
                    else:
                        rc = 1
            new_state[key] = {"runs": runs, "posted": posted, "since": since, "logged": logged,
                              "decoy": decoy, "host": series["metric"].get("host", "")}
        for key, prev in state.items():
            if not key.startswith(rule["name"] + "{") or key in seen:
                continue
            if mode != "run":
                new_state[key] = prev
                continue
            # The resolve time is fixed on the first run that sees the series gone, so a retry repeats it.
            resolved_at = prev.get("resolved_at") or int(now())
            metric = {"host": prev.get("host", "")}
            ok = True
            if prev.get("logged") and not event_fn("alert.resolved", rule, key, metric, prev.get("since", 0), resolved_at):
                ok = False
            if prev["posted"] and not prev.get("decoy"):
                if not post_fn("RESOLVED: %s (%s). From %s." % (rule["summary"], key, HOST)):
                    ok = False
            if not ok:
                rc = 1
                new_state[key] = dict(prev, resolved_at=resolved_at)  # the marker stays and the next run retries
        lines.append("rule %s: examined, %d firing" % (rule["name"], len(result)))
    # Every query failing means the store is down, and a down store cannot fire its own rules.
    prev = state.get("store{}", {"runs": 0, "posted": False})
    if rules and failed == len(rules):
        runs, posted = prev["runs"] + 1, prev["posted"]
        if mode == "run" and runs >= 2 and not posted:
            posted = bool(post_fn("FIRING: the metrics store at %s answers no query. From %s." % (PROM, HOST)))
            rc = 1 if not posted else rc
        new_state["store{}"] = {"runs": runs, "posted": posted}
    elif prev["posted"] and mode == "run":
        if not post_fn("RESOLVED: the metrics store answers again. From %s." % HOST):
            rc = 1
            new_state["store{}"] = prev
    elif mode != "run" and "store{}" in state:
        new_state["store{}"] = prev
    return rc, lines, new_state


def main(argv):
    mode = "run"
    if argv[1:] == ["--check"]:
        mode = "check"
    elif argv[1:] == ["--test"]:
        ok = post("metric-alerts test from %s. If you can read this, the bot token and the DM work." % HOST)
        print("posted" if ok else "post failed")
        return 0 if ok else 1
    elif argv[1:]:
        print("usage: metric-alerts [--check|--test]", file=sys.stderr)
        return 2
    rules = json.load(open(RULES))
    try:
        state = json.load(open(STATE))
    except (OSError, ValueError):
        state = {}
    rc, lines, new_state = evaluate(rules, state, mode=mode)
    print("\n".join(lines))
    print("examined %d rules" % len(rules))
    if mode == "run":
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(new_state, fh)
        os.replace(tmp, STATE)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
