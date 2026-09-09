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

from uptime_kuma_api import UptimeKumaApi, MonitorType, NotificationType, UptimeKumaException

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


def notif_ids(monitor):
    """Ids attached to a monitor, whatever shape this Kuma reports them in.

    ⚠ notificationIDList is a LIST of ids here ([1]), and a dict keyed by id in other
    versions and in uptime-kuma-api's own docs. Assuming either one crashes on the
    other, and assuming the dict shape is what made a first attempt report all 19
    monitors unattached when they were already bound.
    """
    raw = monitor.get("notificationIDList") or []
    if isinstance(raw, dict):
        return {int(k) for k, v in raw.items() if v}
    return {int(i) for i in raw}


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
        "notifications_created": [], "notifications_updated": [],
        "notifications_attached": [],
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

        # --- notifications -------------------------------------------------
        # ⚠ A MONITOR WITH NO NOTIFICATION IS A LOG, NOT AN ALERT. Kuma recorded
        # 1724 consecutive DOWN heartbeats across a nine-hour Vault outage on
        # 2026-09-09 and reached nobody, because 19 monitors had zero channels
        # attached (PET-374). Detection was never the weak part.
        #
        # isDefault + applyExisting is the whole point: it attaches to every
        # monitor that exists now AND every one added later, so a new monitor
        # cannot be born silent. Per-monitor wiring is what rots.
        by_notif = {n["name"]: n for n in api.get_notifications()}
        for spec in cfg.get("notifications", []):
            name = spec["name"]
            ntype = spec["type"]
            if not hasattr(NotificationType, ntype.upper()):
                result["failed"].append(
                    {"name": name, "error": f"unknown notification type {ntype!r}"}
                )
                continue
            # Provider fields (discordWebhookUrl, ntfyserverurl, …) come through
            # verbatim. Kuma names them inconsistently and the declaration is the
            # place that knows which; this only strips its own control keys.
            fields = {k: v for k, v in spec.items() if k not in ("name", "type")}
            missing = [k for k, v in fields.items() if v in (None, "")]
            if missing:
                # Fail rather than warn. A channel declared without its secret is
                # exactly the silent-success shape this whole item exists to end.
                result["failed"].append(
                    {"name": name, "error": f"declared but empty: {', '.join(missing)}"}
                )
                continue
            try:
                if name not in by_notif:
                    api.add_notification(
                        name=name,
                        type=getattr(NotificationType, ntype.upper()),
                        isDefault=True,
                        applyExisting=True,
                        **fields,
                    )
                    result["notifications_created"].append(name)
                else:
                    api.edit_notification(
                        by_notif[name]["id"],
                        name=name,
                        type=getattr(NotificationType, ntype.upper()),
                        isDefault=True,
                        applyExisting=True,
                        **fields,
                    )
                    result["notifications_updated"].append(name)
            except (UptimeKumaException, Exception) as exc:  # noqa: BLE001
                result["failed"].append({"name": name, "error": str(exc)})

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

        # ⚠ ATTACH EXPLICITLY. applyExisting=True on add_notification does NOT attach to
        # monitors that already exist — verified 2026-09-09, when it created the channel
        # and left all 19 monitors with notificationIDList empty. Setting it per monitor
        # is the only thing that actually binds them, so do that and let the check below
        # confirm it rather than trusting either mechanism.
        if cfg.get("notifications"):
            declared = {spec["name"] for spec in cfg["notifications"]}
            wanted = {n["id"] for n in api.get_notifications() if n["name"] in declared}
            for mon in api.get_monitors():
                current = notif_ids(mon)
                if wanted <= current:
                    continue
                try:
                    api.edit_monitor(mon["id"], notificationIDList=sorted(current | wanted))
                    result["notifications_attached"].append(mon["name"])
                except (UptimeKumaException, Exception) as exc:  # noqa: BLE001
                    result["failed"].append(
                        {"name": f"attach:{mon['name']}", "error": str(exc)}
                    )

        # ⚠ PROVE THE ATTACHMENT, DO NOT ASSUME applyExisting WORKED. The whole
        # point of PET-374 is that a monitor which notifies nobody looks exactly
        # like one that does. Count the silent ones and fail on them, so this
        # cannot regress quietly the way it arrived.
        finals = api.get_monitors()
        result["monitor_total"] = len(finals)
        if cfg.get("notifications"):
            silent = [m["name"] for m in finals if not notif_ids(m)]
            result["monitors_without_notification"] = silent
            if silent:
                result["failed"].append({
                    "name": "notification-attachment",
                    "error": (
                        f"{len(silent)} of {len(finals)} monitors have no notification "
                        f"attached: {', '.join(sorted(silent))}"
                    ),
                })
    finally:
        try:
            api.disconnect()
        except Exception:  # noqa: BLE001
            pass

    print(json.dumps(result, indent=2))
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
