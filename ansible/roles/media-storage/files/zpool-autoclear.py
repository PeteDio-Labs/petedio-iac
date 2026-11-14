#!/usr/bin/env python3
"""zpool-autoclear (PET-914): clear a suspended pool once every one of its disks answers again.

Managed by petedio-iac, roles/media-storage. Do not edit it on the host.

WHY. The JMicron USB enclosure on pve02 can drop off the bus and return a second later
(2026-11-08 and 2026-11-13). ZFS suspends every pool on it, and the pools stay suspended until
`zpool clear`, although the disks are back. Plex then fails every title it has not cached.

WHAT. A one-minute timer runs this, and so does a udev rule on the enclosure's disks. For each
pool in the config, it reads the pool's state from kstat, which answers while the pool is
suspended. A SUSPENDED pool is cleared only when every disk in it exists and returns a read.
Each pool is cleared at most max_per_hour times an hour. Past that the script holds, because an
enclosure that keeps dropping needs a reboot or new hardware, not another clear. The runbook is
vault/Incidents/2026-11-08-media-pools-suspended.md.

It writes node-exporter textfile metrics. metric-alerts on metrics-240 reads them and posts the
DM, so this host needs no Discord credential.

Every path comes from the config, so tests run it against a fake kstat, fake disks and a fake
zpool binary (ansible/tests/zpool-autoclear.yml).
"""
import fcntl
import json
import os
import subprocess
import sys
import time

CONFIG = os.environ.get("ZPOOL_AUTOCLEAR_CONFIG", "/etc/zpool-autoclear.json")
HOUR = 3600


def log(msg):
    # systemd puts stdout in the journal under the unit's name.
    print(msg, flush=True)


def pool_state(cfg, pool):
    try:
        with open(os.path.join(cfg["kstat_dir"], pool, "state")) as fh:
            return fh.read().strip()
    except OSError:
        return "MISSING"


def disk_answers(cfg, dev):
    """True when the disk exists and returns one 4 KiB read. A by-id link can point at nothing."""
    path = os.path.join(cfg["dev_dir"], dev)
    if not os.path.exists(path):
        return False
    cmd = ["dd", "if=" + path, "of=/dev/null", "bs=4096", "count=1"]
    if cfg.get("direct_io", True):
        cmd.append("iflag=direct")
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def load_state(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def metrics(state, now):
    pools = sorted(state.items())
    lines = [
        "# HELP zpool_autoclear_last_run_timestamp_seconds When zpool-autoclear last finished a run.",
        "# TYPE zpool_autoclear_last_run_timestamp_seconds gauge",
        "zpool_autoclear_last_run_timestamp_seconds %d" % now,
        "# HELP zpool_autoclear_last_clear_timestamp_seconds When zpool-autoclear last ran zpool clear on the pool, or 0 for never.",
        "# TYPE zpool_autoclear_last_clear_timestamp_seconds gauge",
    ]
    lines += ['zpool_autoclear_last_clear_timestamp_seconds{zpool="%s"} %d' % (p, s["last_clear"]) for p, s in pools]
    lines += ["# HELP zpool_autoclear_clears_total zpool clear runs since the state file was created.",
              "# TYPE zpool_autoclear_clears_total counter"]
    lines += ['zpool_autoclear_clears_total{zpool="%s"} %d' % (p, s["total"]) for p, s in pools]
    lines += ["# HELP zpool_autoclear_held 1 when the pool is suspended and the hourly limit stops another clear.",
              "# TYPE zpool_autoclear_held gauge"]
    lines += ['zpool_autoclear_held{zpool="%s"} %d' % (p, s["held"]) for p, s in pools]
    return "\n".join(lines) + "\n"


def run(cfg):
    state_path = os.path.join(cfg["state_dir"], "state.json")
    state = load_state(state_path)
    for pool, devices in sorted(cfg["pools"].items()):
        s = state.setdefault(pool, {"clears": [], "last_clear": 0, "total": 0, "held": 0})
        now = time.time()
        s["clears"] = [t for t in s["clears"] if now - t < HOUR]
        s["held"] = 0
        if pool_state(cfg, pool) != "SUSPENDED":
            continue
        if len(s["clears"]) >= cfg["max_per_hour"]:
            s["held"] = 1
            log("%s is SUSPENDED and was cleared %d times in the last hour, so I hold. The enclosure "
                "is unstable: reboot pve02 (vault/Incidents/2026-11-08-media-pools-suspended.md)."
                % (pool, len(s["clears"])))
            continue
        # The udev rule fires as the first disk appears, before the others. Wait for the rest.
        deadline = now + cfg["wait_seconds"]
        while True:
            missing = [d for d in devices if not disk_answers(cfg, d)]
            if not missing or time.time() >= deadline:
                break
            time.sleep(5)
        if missing:
            log("%s is SUSPENDED, and %s does not answer. The next run retries." % (pool, ", ".join(missing)))
            continue
        log("%s is SUSPENDED, and all %d disks answer. Running zpool clear %s." % (pool, len(devices), pool))
        try:
            rc = subprocess.run([cfg["zpool"], "clear", pool], timeout=300).returncode
        except (OSError, subprocess.TimeoutExpired) as err:
            rc = repr(err)
        # Count the attempt whatever it returned, so a clear that fails still meets the limit.
        t = time.time()
        s["clears"].append(t)
        s["last_clear"] = t
        s["total"] += 1
        log("zpool clear %s returned %s. The pool is %s." % (pool, rc, pool_state(cfg, pool)))
    write_atomic(state_path, json.dumps(state, indent=1, sort_keys=True))
    write_atomic(os.path.join(cfg["textfile_dir"], "zpool_autoclear.prom"), metrics(state, time.time()))


def main():
    with open(CONFIG) as fh:
        cfg = json.load(fh)
    os.makedirs(cfg["state_dir"], exist_ok=True)
    lock = open(cfg["lock"], "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("Another zpool-autoclear run holds the lock, so this one exits.")
        return 0
    run(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
