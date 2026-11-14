#!/usr/bin/env python3
"""Offline tests for scripts/staging-power.py: the decision, and the two GitHub readers."""
import datetime as dt
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("sp", pathlib.Path(__file__).with_name("staging-power.py"))
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

NOW = dt.datetime(2026, 11, 14, 12, 0, tzinfo=dt.timezone.utc)
FRESH = NOW - dt.timedelta(minutes=20)
STALE = NOW - dt.timedelta(hours=3, minutes=1)
checked = 0


def eq(got, want, label):
    global checked
    checked += 1
    if got != want:
        print(f"FAIL {label}: got {got!r}, want {want!r}")
        sys.exit(1)


# decide: every cell of the table
eq(sp.decide(True, FRESH, NOW, False)[0], "start", "pending+recent+stopped")
eq(sp.decide(True, FRESH, NOW, True)[0], "none", "pending+recent+running")
eq(sp.decide(False, FRESH, NOW, True)[0], "stop", "promoted+running (send it)")
eq(sp.decide(False, FRESH, NOW, False)[0], "none", "promoted+stopped")
eq(sp.decide(True, STALE, NOW, True)[0], "stop", "pending+idle+running")
eq(sp.decide(True, STALE, NOW, False)[0], "none", "pending+idle+stopped")
eq(sp.decide(True, None, NOW, True)[0], "stop", "no UI commit seen, running")
eq(sp.decide(True, None, NOW, False)[0], "none", "no UI commit seen, stopped")
# the idle boundary is exclusive at exactly 3 hours
eq(sp.decide(True, NOW - dt.timedelta(hours=3), NOW, True)[0], "stop", "exactly 3h is idle")

# pending_from_files
eq(sp.pending_from_files([]), False, "identical branches")
eq(sp.pending_from_files([{"filename": ".github/workflows/sync-staging.yml"}]), False, "only .github differs")
eq(sp.pending_from_files([{"filename": ".github/x"}, {"filename": "src/pages.ts"}]), True, "a source file differs")
eq(sp.pending_from_files([{"filename": ".github/x"}] * sp.PAGE), True, "a full page of .github hides more: pending")

# newest_ui_commit skips the sync bot by author and by subject
def commit(sha, login, msg):
    return {"sha": sha, "author": {"login": login}, "commit": {"message": msg}}

log = [
    commit("a" * 40, "github-actions[bot]", "Merge main into staging"),
    commit("b" * 40, "petedillo", "Merge main into staging by hand"),
    commit("c" * 40, "petedillo", "Tighten the hero spacing"),
    commit("d" * 40, "petedillo", "older"),
]
eq(sp.newest_ui_commit(log)["sha"], "c" * 40, "skips bot and sync-subject commits")
eq(sp.newest_ui_commit(log[:1]), None, "only sync commits: none")
eq(sp.newest_ui_commit([]), None, "empty log")
eq(sp.newest_ui_commit([{"sha": "e" * 40, "author": None, "commit": {"message": "UI fix"}}])["sha"], "e" * 40, "author may be null")

print(f"staging-power: {checked} checks passed")
