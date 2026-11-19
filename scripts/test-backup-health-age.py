#!/usr/bin/env python3
"""Test backup-health's per-job archive age limit (PET-960) without a Proxmox node.

backup-health once held every guest to one 26 h limit. MED-11 moved plex-remote 244 to a weekly
job, so the check failed six days of seven by design. This drives the schedule reader, the
per-guest limits and the archive check against fakes, and prints what it examined.

Run:  python3 scripts/test-backup-health-age.py
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import time

HEALTH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "ansible", "roles", "backup-store", "files", "backup-health")
os.environ["BACKUP_HEALTH_NO_PUSH"] = "1"
loader = importlib.machinery.SourceFileLoader("backup_health", HEALTH)
spec = importlib.util.spec_from_loader("backup_health", loader)
bh = importlib.util.module_from_spec(spec)
loader.exec_module(bh)

failures = []
examined = 0


def check(cond, msg):
    global examined
    examined += 1
    print(f"{'ok  ' if cond else 'FAIL'} {msg}")
    if not cond:
        failures.append(msg)


# The schedule reader.
for sched, want in [("02:30", 24.0), ("2:30", 24.0), ("sun 04:00", 168.0), ("SUN 04:00", 168.0),
                    ("mon..fri 02:30", 72.0), ("mon,wed,fri 03:00", 72.0), ("sat,sun 01:00", 144.0),
                    ("mon..sun 02:00", 24.0)]:
    check(bh.longest_gap_h(sched) == want, f"{sched!r} -> {want} h")
for sched in ["", None, "*-*-01 03:00", "02:30,14:30", "funday 04:00", "mon..xyz 02:00", "sun"]:
    check(bh.longest_gap_h(sched) is None, f"{sched!r} is unreadable, so None")

check(bh.job_limit_h("02:45") == 26.0, "a daily job keeps the 26 h limit")
check(bh.job_limit_h("sun 04:00") == 170.0, "a weekly job allows 170 h (7 days plus 2 h)")
check(bh.job_limit_h("*-*-01 03:00") == 26.0, "an unreadable schedule keeps the daily limit")

# covered(): limits per guest, from fake jobs.
JOBS = [
    {"id": "nightly", "node": "pve03", "enabled": 1, "all": 1, "exclude": "223,244,247", "schedule": "02:45"},
    {"id": "plex-remote-weekly", "node": "pve03", "enabled": 1, "vmid": "244", "schedule": "sun 04:00"},
    {"id": "elsewhere", "node": "pve02", "enabled": 1, "all": 1, "schedule": "02:30"},
    {"id": "off", "node": "pve03", "enabled": 0, "vmid": "300", "schedule": "02:00"},
]
GUESTS = {246: ("lxc", "ollama", ""), 244: ("lxc", "plex-remote", ""), 247: ("lxc", "claude-247", ""), 300: ("lxc", "off", "")}
bh.NODE = "pve03"
bh.pvesh = lambda path, *a: JOBS
bh.problems.clear()
ids, limits = bh.covered(GUESTS)
check(ids == {246, 244, 300}, f"covered guests are 246, 244 and 300 (got {sorted(ids)})")
check(limits == {246: 26.0, 244: 170.0, 300: 26.0}, f"limits: 246 daily, 244 weekly (got {limits})")

# A guest in a daily and a weekly job keeps the stricter limit.
JOBS.append({"id": "both", "node": "pve03", "enabled": 1, "vmid": "244", "schedule": "02:00"})
ids, limits = bh.covered(GUESTS)
check(limits[244] == 26.0, "a guest in a daily and a weekly job keeps 26 h")
JOBS.pop()


def run_archives(ages_h, limits_):
    with tempfile.TemporaryDirectory() as mnt:
        os.makedirs(os.path.join(mnt, "dump"))
        for vmid, age in ages_h.items():
            path = os.path.join(mnt, "dump", f"vzdump-lxc-{vmid}-2026_11_15-02_53_18.tar.zst")
            open(path, "w").close()
            t = time.time() - age * 3600
            os.utime(path, (t, t))
        bh.MNT = mnt
        bh.problems.clear()
        bh.check_archives(set(ages_h), GUESTS, limits_)
        return list(bh.problems)


# The 2026-11-16 failure: 244 was 27 h old under a daily limit.
p = run_archives({244: 27}, {244: 26.0})
check(len(p) == 1 and "244 plex-remote" in p[0], f"27 h old under a daily limit fails (got {p})")
p = run_archives({244: 27}, {244: 170.0})
check(p == [], f"27 h old under the weekly limit passes (got {p})")
p = run_archives({244: 75}, {244: 170.0})
check(p == [], "75 h old under the weekly limit passes")
p = run_archives({244: 171}, {244: 170.0})
check(len(p) == 1 and "limit 170 h" in p[0], f"171 h old under the weekly limit fails and names the limit (got {p})")
p = run_archives({246: 27, 244: 100}, {246: 26.0, 244: 170.0})
check(len(p) == 1 and "246" in p[0], f"a stale daily guest still fails beside a fresh weekly one (got {p})")
p = run_archives({}, {})
check(p == [], "no covered guests adds no archive problem")

print(f"== examined {examined} checks, {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
