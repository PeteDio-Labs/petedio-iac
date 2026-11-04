#!/usr/bin/env python3
"""Test provision_kuma.retire_monitors (PET-590) without a Kuma.

Retirement deletes a live monitor, so a regression must not go unnoticed. This drives the
function against a fake API and checks the deletion target, the `retired` result, the rerun
and the failure paths.

Run:  python3 scripts/test-kuma-retire.py
"""
import importlib.util
import os
import sys
import types

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FILE = os.path.join(ROOT, "ansible", "roles", "uptime-kuma", "files", "provision_kuma.py")

try:
    import uptime_kuma_api  # noqa: F401
except ImportError:
    stub = types.ModuleType("uptime_kuma_api")

    class _Any:
        """Any attribute reads as its own name, so module-level enum lookups succeed."""

        def __getattr__(self, name):
            return name

    class UptimeKumaException(Exception):
        pass

    for name in ("MaintenanceStrategy", "MonitorType", "NotificationType"):
        setattr(stub, name, _Any())
    stub.UptimeKumaApi = object
    stub.UptimeKumaException = UptimeKumaException
    sys.modules["uptime_kuma_api"] = stub

spec = importlib.util.spec_from_file_location("provision_kuma", FILE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeApi:
    def __init__(self, fail_ids=()):
        self.deleted = []
        self.fail_ids = set(fail_ids)

    def delete_monitor(self, monitor_id):
        if monitor_id in self.fail_ids:
            raise RuntimeError("boom")
        self.deleted.append(monitor_id)


def fresh():
    return {"failed": [], "retired": []}


BY_NAME = {"usaa": {"id": 26}, "sonarr": {"id": 3}}
failures = []


def check(label, ok):
    print(("ok   " if ok else "FAIL ") + label)
    if not ok:
        failures.append(label)


# 1. An existing retired monitor is deleted by its own id and reported.
api, res = FakeApi(), fresh()
mod.retire_monitors(api, [{"name": "sonarr"}], ["usaa"], BY_NAME, res)
check("existing monitor: deleted id 26 only", api.deleted == [26])
check("existing monitor: reported retired, no failure", res == {"failed": [], "retired": ["usaa"]})

# 2. Rerun: Kuma no longer has it, so nothing is deleted and nothing fails.
api, res = FakeApi(), fresh()
mod.retire_monitors(api, [{"name": "sonarr"}], ["usaa"], {"sonarr": {"id": 3}}, res)
check("rerun: no delete call", api.deleted == [])
check("rerun: empty result", res == {"failed": [], "retired": []})

# 3. A name that is both declared and retired is refused and never deleted.
api, res = FakeApi(), fresh()
mod.retire_monitors(api, [{"name": "usaa"}], ["usaa"], BY_NAME, res)
check("conflict: no delete call", api.deleted == [])
check("conflict: reported as failed", [f["name"] for f in res["failed"]] == ["usaa"] and res["retired"] == [])

# 4. A delete that raises is reported as failed, not as retired.
api, res = FakeApi(fail_ids={26}), fresh()
mod.retire_monitors(api, [], ["usaa"], BY_NAME, res)
check("delete failure: reported failed with the error", res["failed"] == [{"name": "usaa", "error": "boom"}])
check("delete failure: not reported retired", res["retired"] == [])

# 5. No retired list: nothing happens.
api, res = FakeApi(), fresh()
mod.retire_monitors(api, [], [], BY_NAME, res)
check("empty list: no delete call", api.deleted == [])

if failures:
    print(f"\n{len(failures)} check(s) failed")
    sys.exit(1)
print("\nall checks passed")
