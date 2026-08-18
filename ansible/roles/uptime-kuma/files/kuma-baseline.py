#!/usr/bin/env python3
"""Response-time baselines from Uptime Kuma's raw heartbeat table.

WHY SQLITE AND NOT THE OTHER TWO SOURCES. Kuma exposes three machine-readable
surfaces and only one of them can answer "what was normal before the fault":

  * /metrics (Prometheus) is a gauge sampled at scrape time. It holds the CURRENT
    value and no history at all, so a baseline cannot be computed from it unless
    something else has been scraping it into a TSDB all along.
  * /api/status-page/heartbeat/<slug> returns only the most recent beats per
    monitor — roughly 100, which at a 20s interval is about 33 minutes, and it
    takes no time-range argument.
  * The `heartbeat` table keeps EVERY beat for the full retention period with a
    timestamp and a `ping` in milliseconds, and accepts an arbitrary range.

So this reads the table. Times are UTC — the container runs TZ=UTC so a DST
boundary cannot put a one-hour step inside a 30-day window.

Exit status is 0 when the monitor is inside its band, 2 when it is outside, so
this can gate a shell loop while waiting for recovery.
"""
import argparse
import json
import sqlite3
import statistics
import sys
from datetime import datetime, timedelta, timezone

DB = "/opt/uptime-kuma/data/kuma.db"


def rows(conn, monitor, start, end):
    return conn.execute(
        """SELECT h.time, h.ping, h.status
             FROM heartbeat h JOIN monitor m ON m.id = h.monitor_id
            WHERE m.name = ? AND h.time >= ? AND h.time < ?
            ORDER BY h.time""",
        (monitor, start, end),
    ).fetchall()


def summarise(sample):
    """Up-only response times describe 'normal'; a failed beat has no meaningful ping."""
    up = [r[1] for r in sample if r[2] == 1 and r[1] is not None]
    total = len(sample)
    if not up:
        return {"beats": total, "up_beats": 0, "up_ratio": 0.0, "usable": False}
    mean = statistics.fmean(up)
    sd = statistics.stdev(up) if len(up) > 1 else 0.0
    ordered = sorted(up)
    return {
        "beats": total,
        "up_beats": len(up),
        "up_ratio": round(len(up) / total, 4),
        "mean_ms": round(mean, 2),
        "stdev_ms": round(sd, 2),
        "p50_ms": ordered[len(ordered) // 2],
        "p95_ms": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
        "min_ms": ordered[0],
        "max_ms": ordered[-1],
        # 3-sigma. Wide on purpose: the question is "has it returned to normal",
        # and a tight band would call ordinary jitter a regression.
        "band_low_ms": round(max(0.0, mean - 3 * sd), 2),
        "band_high_ms": round(mean + 3 * sd, 2),
        "usable": True,
    }


def fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--db", default=DB)
    p.add_argument("--monitor", help="monitor name; omit with --all")
    p.add_argument("--all", action="store_true", help="every monitor")
    p.add_argument("--list", action="store_true", help="list monitor names and exit")
    p.add_argument("--dump", action="store_true", help="print raw beats instead of stats")
    p.add_argument("--baseline-mins", type=float, default=60.0,
                   help="length of the pre-fault baseline window (default 60)")
    p.add_argument("--recent-mins", type=float, default=5.0,
                   help="length of the current window compared against it (default 5)")
    p.add_argument("--fault-start",
                   help="UTC 'YYYY-MM-DD HH:MM:SS'; baseline ends here. Default: now-recent")
    p.add_argument("--from", dest="frm", help="explicit UTC window start for --dump")
    p.add_argument("--to", dest="to", help="explicit UTC window end for --dump")
    a = p.parse_args()

    conn = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)

    if a.list:
        for (n,) in conn.execute("SELECT name FROM monitor ORDER BY name"):
            print(n)
        return 0

    names = ([r[0] for r in conn.execute("SELECT name FROM monitor ORDER BY name")]
             if a.all else [a.monitor])
    if not names or names == [None]:
        p.error("give --monitor NAME, or --all, or --list")

    now = datetime.now(timezone.utc).replace(tzinfo=None)

    if a.dump:
        start = a.frm or fmt(now - timedelta(minutes=a.baseline_mins))
        end = a.to or fmt(now)
        out = {m: [{"time": t, "ping_ms": ping, "status": st}
                   for t, ping, st in rows(conn, m, start, end)] for m in names}
        print(json.dumps({"from": start, "to": end, "beats": out}, indent=2))
        return 0

    fault = (datetime.strptime(a.fault_start, "%Y-%m-%d %H:%M:%S")
             if a.fault_start else now - timedelta(minutes=a.recent_mins))
    b_start, b_end = fmt(fault - timedelta(minutes=a.baseline_mins)), fmt(fault)
    c_start, c_end = fmt(fault), fmt(fault + timedelta(minutes=a.recent_mins))

    report, worst = {}, 0
    for m in names:
        base = summarise(rows(conn, m, b_start, b_end))
        cur = summarise(rows(conn, m, c_start, c_end))
        entry = {"baseline_window": [b_start, b_end], "current_window": [c_start, c_end],
                 "baseline": base, "current": cur}
        if base["usable"] and cur["usable"]:
            inside = base["band_low_ms"] <= cur["mean_ms"] <= base["band_high_ms"]
            entry["recovered"] = bool(inside and cur["up_ratio"] == 1.0)
            entry["verdict"] = ("inside baseline band" if inside
                                else "OUTSIDE baseline band")
            if not entry["recovered"]:
                worst = 2
        else:
            entry["recovered"] = False
            entry["verdict"] = "insufficient data (no UP beats in one window)"
            worst = 2
        report[m] = entry

    print(json.dumps(report, indent=2))
    return worst


if __name__ == "__main__":
    sys.exit(main())
