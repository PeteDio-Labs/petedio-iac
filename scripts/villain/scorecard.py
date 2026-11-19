#!/usr/bin/env python3
"""Lab Villains scorecard (PET-954): did detection and recovery work after a strike?

    scripts/villain/scorecard.py --since 2026-11-26T15:00:00Z --victims 251,211 [--undo-at ISO]
                                 [--discord yes|no|unknown]

Reads Uptime Kuma's fault-study status page and its heartbeat JSON, then reports for each victim
how long Kuma took to see it DOWN and, after an undo, to see it UP. It prints how many monitors and
beats it read, so "0 detections" never hides "read 0 beats". It exits 1 when a victim was not
detected, has no monitor, or no beats were read.

Discord and the watchdog are not read here. pete-bot offers no read path for sent DMs, and the
watchdog probes fixed targets, no decoy among them. Pass --discord with what Pedro saw; the
default, `unknown`, prints as not examined. Reads only; it changes nothing.
"""
import argparse
import json
import sys
import urllib.request
from datetime import datetime, timezone

KUMA = "http://192.168.50.4:3001"
SLUG = "fault-study"


def fetch(url):
    with urllib.request.urlopen(url, timeout=15) as r:  # noqa: S310 (fixed LAN URL)
        return json.load(r)


def ts(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)


def beat_time(b):
    t = b["time"].replace(" ", "T")
    d = datetime.fromisoformat(t.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def monitor_ids(status):
    out = {}
    for g in status.get("publicGroupList", []):
        for m in g.get("monitorList", []):
            out[m["name"]] = str(m["id"])
    return out


def score(status, beats, victims, since, undo_at):
    ids = monitor_ids(status)
    lists = beats.get("heartbeatList", {})
    rows, read = [], sum(len(v) for v in lists.values())
    for vmid in victims:
        name = next((n for n in ids if n.endswith(f"-{vmid}") and n.startswith("decoy-")), None)
        if not name:
            rows.append({"vmid": vmid, "error": "no Kuma monitor named decoy-*-%s" % vmid})
            continue
        bl = sorted(lists.get(ids[name], []), key=beat_time)
        down = next((b for b in bl if b["status"] == 0 and beat_time(b) >= since), None)
        row = {"vmid": vmid, "monitor": name, "beats": len(bl), "detected_s": None, "recovered_s": None}
        if down:
            row["detected_s"] = round((beat_time(down) - since).total_seconds())
            after = undo_at or beat_time(down)
            up = next((b for b in bl if b["status"] == 1 and beat_time(b) >= after), None)
            if up:
                row["recovered_s"] = round((beat_time(up) - after).total_seconds())
        rows.append(row)
    return rows, len(ids), read


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", required=True, help="strike start, ISO 8601")
    ap.add_argument("--victims", required=True, help="comma-separated vmids")
    ap.add_argument("--undo-at", help="when the undo ran, ISO 8601")
    ap.add_argument("--discord", choices=["yes", "no", "unknown"], default="unknown")
    ap.add_argument("--kuma", default=KUMA)
    ap.add_argument("--status-file")
    ap.add_argument("--beats-file")
    a = ap.parse_args(argv)
    try:
        status = json.load(open(a.status_file)) if a.status_file else fetch(f"{a.kuma}/api/status-page/{SLUG}")
        beats = json.load(open(a.beats_file)) if a.beats_file else fetch(f"{a.kuma}/api/status-page/heartbeat/{SLUG}")
    except Exception as e:  # a failed read is a failure, never an empty result
        print(f"scorecard: FAILED to read Kuma: {e}", file=sys.stderr)
        return 1
    victims = [v.strip() for v in a.victims.split(",") if v.strip()]
    rows, monitors, read = score(status, beats, victims, ts(a.since), ts(a.undo_at) if a.undo_at else None)
    print(f"scorecard: read {monitors} monitors and {read} beats; scoring {len(victims)} victim(s)")
    bad = read == 0
    for r in rows:
        if "error" in r:
            print(f"  {r['vmid']}: FAIL {r['error']}"); bad = True
        elif r["detected_s"] is None:
            print(f"  {r['vmid']} {r['monitor']}: FAIL never seen DOWN in {r['beats']} beats"); bad = True
        else:
            rec = f"UP again {r['recovered_s']} s later" if r["recovered_s"] is not None else "not yet UP"
            if r["recovered_s"] is None and a.undo_at:
                rec += ": FAIL no UP beat after the undo"; bad = True
            print(f"  {r['vmid']} {r['monitor']}: Kuma saw DOWN after {r['detected_s']} s; {rec} ({r['beats']} beats)")
    print("  Discord: " + {"yes": "Pedro saw the alert", "no": "Pedro saw NO alert: FAIL",
                           "unknown": "not examined"}[a.discord])
    print("  watchdog: not examined (it probes fixed targets, no decoy)")
    return 1 if bad or a.discord == "no" else 0


if __name__ == "__main__":
    sys.exit(main())
