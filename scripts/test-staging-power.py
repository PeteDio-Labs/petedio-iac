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


# decide: every cell of the table. since is when the box last started (running) or stopped.
UP2 = NOW - dt.timedelta(hours=2)
UP25 = NOW - dt.timedelta(hours=25)
PUSH_OLD = NOW - dt.timedelta(hours=30)
eq(sp.decide(True, FRESH, NOW, False, PUSH_OLD)[0], "start", "pending, push newer than the last shutdown, stopped")
eq(sp.decide(True, FRESH, NOW, True, UP2)[0], "none", "pending, up 2h")
eq(sp.decide(False, FRESH, NOW, True, UP2)[0], "teardown", "promoted+running (merged to main)")
eq(sp.decide(False, FRESH, NOW, False, UP2)[0], "none", "promoted+stopped")
eq(sp.decide(True, PUSH_OLD, NOW, True, UP25)[0], "stop", "pending, up 25h: the limit stops it")
eq(sp.decide(True, FRESH, NOW, True, UP25)[0], "stop", "a recent push does not extend the 24h limit")
eq(sp.decide(True, PUSH_OLD, NOW, False, UP25)[0], "none", "stopped at the limit: stays off, the push is older than the shutdown")
eq(sp.decide(True, FRESH, NOW, False, UP25)[0], "start", "a push after the shutdown starts it again")
eq(sp.decide(True, None, NOW, False, UP25)[0], "none", "no push seen, stopped")
eq(sp.decide(True, FRESH, NOW, True, None)[0], "none", "running, no start time from the node: no stop, and it says why")
eq(sp.decide(True, FRESH, NOW, False, None)[0], "start", "stopped, no shutdown time: a push starts it")
eq(sp.decide(True, FRESH, NOW, True, NOW - dt.timedelta(hours=24))[0], "stop", "exactly 24h is the limit")
eq(sp.decide(True, FRESH, NOW, True, NOW - dt.timedelta(hours=23, minutes=59))[0], "none", "23h59 is under the limit")
eq(sp.decide(True, UP25, NOW, False, UP25)[0], "none", "a push at the shutdown time is not newer")
# a long-idle box (the old 3h rule) now stays up
eq(sp.decide(True, NOW - dt.timedelta(hours=10), NOW, True, NOW - dt.timedelta(hours=11))[0], "none", "10h since the push, up 11h: no idle stop")

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

# Dashboard staging shares the container (newest_asset_time and combine).
eq(sp.newest_asset_time({"assets": []}), None, "release with no asset")
eq(sp.newest_asset_time({}), None, "release without an assets key")
eq(sp.newest_asset_time({"assets": [{"updated_at": "2026-11-17T10:00:00Z"}, {"updated_at": "2026-11-17T12:00:00Z"}]}),
   dt.datetime(2026, 11, 17, 12, 0, tzinfo=dt.timezone.utc), "newest asset wins")
eq(sp.combine([(False, None), (False, None)]), (False, None), "nothing pending")
eq(sp.combine([(True, FRESH), (False, FRESH)]), (True, FRESH), "one pending")
eq(sp.combine([(False, FRESH), (True, STALE)]), (True, STALE), "a recent push on a promoted site is ignored")
eq(sp.combine([(True, STALE), (True, FRESH)]), (True, FRESH), "newest pending push wins")
eq(sp.combine([(True, None), (False, FRESH)]), (True, None), "pending with no push time")
eq(sp.decide(*sp.combine([(False, FRESH), (True, STALE)]), NOW, True, UP2)[0], "none", "promoted site's push is ignored; the other site is pending, so no teardown")
eq(sp.decide(*sp.combine([(True, STALE), (True, FRESH)]), NOW, False, PUSH_OLD)[0], "start", "dashboard work starts the box")

print(f"staging-power: {checked} checks passed")
