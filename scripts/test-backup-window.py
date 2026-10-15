#!/usr/bin/env python3
"""Test pve03's backup maintenance window (PET-635) without a Kuma or a Proxmox node.

Two pieces keep the 02:45 backup quiet, and each can fail silently:

- provision_kuma.py reconciles the Kuma maintenance window. A window that names a
  renamed monitor, or one that the provisioner re-edits on every run, would pass a
  deploy and still page Pedro, or report a change that never happened.
- backup-health times the vzdump job against the window. A check that reads the wrong
  run passes while the job outgrows the window.

This drives both against fakes. When uptime-kuma-api is installed, the fake Kuma also
runs the library's own argument checks on every maintenance it receives.

Run:  python3 scripts/test-backup-window.py
"""
import importlib.machinery
import importlib.util
import os
import sys
import time
import types

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
KUMA_FILES = os.path.join(ROOT, "ansible", "roles", "uptime-kuma", "files")
HEALTH = os.path.join(ROOT, "ansible", "roles", "backup-store", "files", "backup-health")

try:
    import uptime_kuma_api
    from uptime_kuma_api.api import _check_arguments_maintenance
    REAL_LIB = True
except ImportError:
    # Stub the names provision_kuma.py imports, so the reconcile logic still runs.
    from enum import Enum

    stub = types.ModuleType("uptime_kuma_api")

    class MaintenanceStrategy(str, Enum):
        CRON = "cron"

    stub.MaintenanceStrategy = MaintenanceStrategy
    stub.MonitorType = Enum("MonitorType", "HTTP PORT DNS PUSH KEYWORD")
    stub.NotificationType = Enum("NotificationType", "WEBHOOK")
    stub.UptimeKumaApi = object
    stub.UptimeKumaException = type("UptimeKumaException", (Exception,), {})
    sys.modules["uptime_kuma_api"] = stub
    REAL_LIB = False

sys.path.insert(0, KUMA_FILES)
import provision_kuma  # noqa: E402

failures = []


def check(cond, msg):
    print(f"{'ok  ' if cond else 'FAIL'} {msg}")
    if not cond:
        failures.append(msg)


class FakeKuma:
    """The slice of UptimeKumaApi that reconcile_maintenances calls."""

    def __init__(self, monitors):
        self.monitors = [{"name": n, "id": i} for i, n in enumerate(monitors, 1)]
        self.maint = {}
        self.links = {}
        self.calls = []

    def get_monitors(self):
        return list(self.monitors)

    def get_maintenances(self):
        return [dict(m, id=i) for i, m in self.maint.items()]

    def _validate(self, data):
        if REAL_LIB:
            built = uptime_kuma_api.UptimeKumaApi.__new__(
                uptime_kuma_api.UptimeKumaApi)._build_maintenance_data(**data)
            _check_arguments_maintenance(built)
            return built
        return dict(data)

    def add_maintenance(self, **kw):
        self.calls.append("add_maintenance")
        mid = len(self.maint) + 1
        self.maint[mid] = self._validate(kw)
        return {"msg": "Added Successfully.", "maintenanceID": mid}

    def edit_maintenance(self, mid, **kw):
        self.calls.append("edit_maintenance")
        merged = dict(self.maint[mid], **kw)
        if REAL_LIB:
            _check_arguments_maintenance(merged)
        self.maint[mid] = merged
        return {"msg": "Saved.", "maintenanceID": mid}

    def get_monitor_maintenance(self, mid):
        return [{"id": i} for i in self.links.get(mid, [])]

    def add_monitor_maintenance(self, mid, monitors):
        self.calls.append("add_monitor_maintenance")
        self.links[mid] = [m["id"] for m in monitors]
        return {"msg": "Added Successfully."}


def fresh_result():
    return {"failed": [], "maintenances_created": [], "maintenances_updated": [],
            "maintenance_monitors": {}}


SPEC = {"title": "pve03-nightly-backup", "description": "test", "cron": "40 2 * * *",
        "duration_minutes": 35, "timezone": "America/New_York",
        "monitors": ["seerr", "vault", "plane"]}


def test_provisioner():
    print(f"== provision_kuma.reconcile_maintenances (uptime-kuma-api checks: "
          f"{'real' if REAL_LIB else 'stubbed'})")
    kuma = FakeKuma(["pve03", "seerr", "vault", "plane", "backups-pve03"])

    r = fresh_result()
    provision_kuma.reconcile_maintenances(kuma, [SPEC], r)
    check(not r["failed"], f"first run fails nothing: {r['failed']}")
    check(r["maintenances_created"] == [SPEC["title"]], "first run creates the window")
    check(sorted(kuma.links[1]) == [2, 3, 4], "the window holds seerr, vault and plane only")
    check(r["maintenance_monitors"] == {SPEC["title"]: 3}, "the result counts 3 monitors")
    live = kuma.maint[1]
    check(str(getattr(live["strategy"], "value", live["strategy"])) == "cron",
          "the window uses the cron strategy")
    check(live["cron"] == "40 2 * * *" and live["durationMinutes"] == 35,
          "the window opens at 02:40 for 35 minutes")
    check(live["timezoneOption"] == "America/New_York", "the window runs on the node's clock")

    kuma.calls.clear()
    r = fresh_result()
    provision_kuma.reconcile_maintenances(kuma, [SPEC], r)
    check(not kuma.calls and not r["maintenances_updated"] and not r["failed"],
          f"a second run changes nothing: calls={kuma.calls}")

    kuma.maint[1]["cron"] = "0 4 * * *"
    r = fresh_result()
    provision_kuma.reconcile_maintenances(kuma, [SPEC], r)
    check(kuma.maint[1]["cron"] == "40 2 * * *" and
          r["maintenances_updated"] == [{"name": SPEC["title"], "changed": ["cron"]}],
          f"a drifted cron is edited back: {r['maintenances_updated']}")

    kuma.links[1] = [2]
    r = fresh_result()
    provision_kuma.reconcile_maintenances(kuma, [SPEC], r)
    check(sorted(kuma.links[1]) == [2, 3, 4], "a drifted monitor list is set back")

    kuma.calls.clear()
    r = fresh_result()
    provision_kuma.reconcile_maintenances(kuma, [dict(SPEC, monitors=["seerr", "sonar"])], r)
    check(r["failed"] and "sonar" in r["failed"][0]["error"] and not kuma.calls,
          "a monitor name that matches nothing fails the run and changes nothing")

    r = fresh_result()
    provision_kuma.reconcile_maintenances(kuma, [dict(SPEC, monitors=[])], r)
    check(r["failed"] and "no monitors" in r["failed"][0]["error"],
          "a window with no monitors fails the run")


def load_health():
    loader = importlib.machinery.SourceFileLoader("backup_health", HEALTH)
    spec = importlib.util.spec_from_loader("backup_health", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def fake_tasks(tasks):
    """Answer like /nodes/{node}/tasks: running tasks only for source=active or all."""
    def pvesh(path, *args):
        source = args[args.index("--source") + 1] if "--source" in args else "archive"
        if source == "all":
            return tasks
        if source == "active":
            return [t for t in tasks if "endtime" not in t]
        if source == "archive":
            return [t for t in tasks if "endtime" in t]
        raise ValueError(f"unknown source {source!r}")
    return pvesh


def run_duration(tasks, max_min):
    bh = load_health()
    bh.MAX_JOB_MIN = max_min
    bh.pvesh = fake_tasks(tasks)
    bh.check_job_duration()
    return bh.problems


def test_health():
    print("== backup-health check_job_duration")
    now = time.time()
    night = now - 3 * 3600
    run = lambda start, mins: {"starttime": int(start), "endtime": int(start + mins * 60)}

    check(run_duration([run(night, 9)], 0) == [], "max_minutes unset: nothing is timed")
    check(run_duration([run(night, 9)], 25) == [], "a 9-minute run passes a 25-minute limit")
    p = run_duration([run(night, 31)], 25)
    check(len(p) == 1 and "31 min" in p[0], f"a 31-minute run fails: {p}")
    p = run_duration([run(night, 31), run(now - 600, 1)], 25)
    check(len(p) == 1 and "31 min" in p[0],
          f"a later short manual backup does not hide the long nightly run: {p}")
    p = run_duration([{"starttime": int(now - 40 * 60)}], 25)
    check(len(p) == 1 and "still running" in p[0], f"a run with no end fails: {p}")
    p = run_duration([run(night - 86400 + 3600, 9), {"starttime": int(night)}], 25)
    check(len(p) == 1 and "still running" in p[0],
          f"a running job beside a finished one still fails (the query asks for all): {p}")
    check(run_duration([run(now - 30 * 3600, 60)], 25) == [],
          "a run older than the archive age limit is ignored")
    check(run_duration([], 25) == [], "no run to time adds no problem (check_archives owns it)")


test_provisioner()
test_health()
print(f"== {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
