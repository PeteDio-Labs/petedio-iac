#!/usr/bin/env python3
"""Reconcile an Uptime Kuma instance against a declared monitor set.

Uptime Kuma v1 has no REST API for creating monitors — the admin surface is
Socket.IO — so this speaks that protocol through uptime-kuma-api rather than
driving the web UI.

Idempotent by monitor NAME: a monitor that is absent gets created, one whose
declared fields have drifted gets edited back, and one that already matches is
left alone. Re-running is therefore safe and is how config changes are applied.

Reads a JSON config on argv[1], writes a JSON result to stdout. Every
credential arrives in that file, never on the command line, so nothing lands in
the process table.
"""
import json
import sys
import time

from uptime_kuma_api import UptimeKumaApi, MonitorType, UptimeKumaException

TYPES = {"http": MonitorType.HTTP, "port": MonitorType.PORT, "dns": MonitorType.DNS}

# Declared-field -> Kuma socket-field. Kuma is inconsistent about case and this
# table is the single place that knows it.
FIELD_MAP = {
    "url": "url",
    "hostname": "hostname",
    "port": "port",
    "ignore_tls": "ignoreTls",
    "accepted_statuscodes": "accepted_statuscodes",
    "dns_resolve_server": "dns_resolve_server",
    "dns_resolve_type": "dns_resolve_type",
    "description": "description",
}


def build_kwargs(spec, cfg):
    """Turn one declared monitor into add_monitor/edit_monitor kwargs."""
    kw = {
        "type": TYPES[spec["type"]],
        "name": spec["name"],
        "interval": cfg["interval"],
        "maxretries": cfg["max_retries"],
        "retryInterval": cfg["retry_interval"],
    }
    for declared, kuma in FIELD_MAP.items():
        if declared in spec:
            kw[kuma] = spec[declared]
    # Only 2xx counts as UP unless a monitor says otherwise. This is what makes
    # a sealed Vault (503) record as DOWN rather than as a probe error.
    kw.setdefault("accepted_statuscodes", ["200-299"])
    if kw["type"] != MonitorType.HTTP:
        kw.pop("accepted_statuscodes", None)
    return kw


def drifted(existing, wanted):
    """Fields where the live monitor disagrees with the declaration."""
    out = {}
    for key, want in wanted.items():
        if key in ("type", "name"):
            continue
        have = existing.get(key)
        if isinstance(want, MonitorType):
            want = want.value
        if key == "accepted_statuscodes":
            if sorted(have or []) != sorted(want or []):
                out[key] = (have, want)
        elif str(have or "") != str(want or ""):
            out[key] = (have, want)
    return out


def main():
    cfg = json.load(open(sys.argv[1]))
    result = {
        "created": [], "updated": [], "unchanged": [],
        "failed": [], "warnings": [],
    }
    api = UptimeKumaApi(cfg["url"], timeout=60)
    try:
        # --- first run: create the admin account ---------------------------
        if api.need_setup():
            api.setup(cfg["admin_user"], cfg["admin_password"])
            result["setup_performed"] = True
            time.sleep(2)
        else:
            result["setup_performed"] = False

        api.login(cfg["admin_user"], cfg["admin_password"])

        # --- retention -----------------------------------------------------
        # Beats older than this are pruned. The study needs >=30 days of raw
        # history to build a baseline, so this failing is worth reporting
        # rather than swallowing.
        try:
            api.set_settings(
                password=cfg["admin_password"],
                keepDataPeriodDays=cfg["retention_days"],
            )
            result["retention_days"] = cfg["retention_days"]
        except Exception as exc:  # noqa: BLE001
            result["warnings"].append(f"set_settings failed: {exc}")

        # --- monitors ------------------------------------------------------
        by_name = {m["name"]: m for m in api.get_monitors()}
        for spec in cfg["monitors"]:
            name = spec["name"]
            kw = build_kwargs(spec, cfg)
            try:
                if name not in by_name:
                    api.add_monitor(**kw)
                    result["created"].append(name)
                else:
                    delta = drifted(by_name[name], kw)
                    if delta:
                        api.edit_monitor(by_name[name]["id"], **kw)
                        result["updated"].append({"name": name, "changed": list(delta)})
                    else:
                        result["unchanged"].append(name)
            except (UptimeKumaException, Exception) as exc:  # noqa: BLE001
                result["failed"].append({"name": name, "error": str(exc)})

        # --- status page: current state as JSON ----------------------------
        slug = cfg["status_page_slug"]
        try:
            existing_slugs = [p["slug"] for p in api.get_status_pages()]
            if slug not in existing_slugs:
                api.add_status_page(slug, cfg["status_page_title"])
            monitors = api.get_monitors()
            api.save_status_page(
                slug,
                title=cfg["status_page_title"],
                description="Machine-readable state for the fault-injection study.",
                publicGroupList=[{
                    "name": "All monitors",
                    "weight": 1,
                    "monitorList": [{"id": m["id"]} for m in monitors],
                }],
            )
            result["status_page"] = slug
            result["status_page_monitors"] = len(monitors)
        except Exception as exc:  # noqa: BLE001
            result["warnings"].append(f"status page failed: {exc}")

        # --- API key for /metrics -----------------------------------------
        # A dedicated key means Prometheus scraping never needs the admin
        # password, and the key can be revoked without a password change.
        try:
            names = [k["name"] for k in api.get_api_keys()]
            if cfg["api_key_name"] not in names:
                key = api.add_api_key(name=cfg["api_key_name"], expires=None, active=True)
                result["api_key"] = key.get("key")
                result["api_key_created"] = True
            else:
                result["api_key_created"] = False
                result["warnings"].append(
                    f"API key '{cfg['api_key_name']}' already exists; "
                    "its secret is only shown at creation."
                )
        except Exception as exc:  # noqa: BLE001
            result["warnings"].append(f"api key failed: {exc}")

        result["monitor_total"] = len(api.get_monitors())
    finally:
        try:
            api.disconnect()
        except Exception:  # noqa: BLE001
            pass

    print(json.dumps(result, indent=2))
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
