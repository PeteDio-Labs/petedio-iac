#!/usr/bin/env python3
"""Report each LXC's DECLARED and RUNNING container features, on one Proxmox node.

Read-only. It decides nothing — roles/lxc-features/tasks/main.yml holds the
declaration and does the converging. This exists because the two states are read
from two different places and neither is a substitute for the other:

  DECLARED  `pct config <vmid>` -> the `features:` line. What the node will use
            the NEXT time the container starts.

  RUNNING   /var/lib/lxc/<vmid>/{config,rules.seccomp}. Proxmox REGENERATES both
            files on every `pct start`, so they are the features the container is
            running under right now.

⚠ WHY BOTH. `features` only takes effect on start. A container whose config says
`nesting=1` while its running instance has no nesting looks correct to every
tool that reads `pct config`, and is still broken. That gap is the entire reason
PET-378 exists: a play that sets the flag and reports success, while the
container keeps running without it, is a false green.

The two runtime markers, each verified against every combination present in the
lab on 2026-09-09 (PVE 9.2.11, pve-container 6.x):

  nesting=1  -> /var/lib/lxc/<vmid>/config contains
                `lxc.apparmor.allow_nesting = 1` (and `allow userns,`).
                Without it the generated profile carries
                `deny mount -> /proc/,` and `deny mount -> /sys/,` instead.

  keyctl=1   -> /var/lib/lxc/<vmid>/rules.seccomp does NOT contain
                `keyctl errno 38`. PVE implements keyctl by DELETING that
                seccomp rule (PVE/LXC.pm: `delete $rules->{keyctl}`), so the
                marker is an absence. Reading it backwards inverts every result.

  Controls used: 236 (nesting only) shows the nesting marker AND the keyctl
  seccomp rule; 109/231/237/245 (no features) show neither marker; 104/223
  (both) show the nesting marker and no seccomp rule.

⚠ ONLY THOSE TWO FLAGS ARE OBSERVABLE AT RUNTIME. `mount`, `fuse`, `mknod` and
`force_rw_sys` leave no marker that was checked, so they are reported as
declared-only and `observable` names what the RUNNING dict can be trusted about.
Do not widen `observable` without finding and testing a marker first.

Emits one JSON object on stdout.
"""

import json
import os
import re
import socket
import subprocess
import sys

# Flags whose runtime state this script can actually prove. See the header.
OBSERVABLE = ["nesting", "keyctl"]

LXC_RUNTIME_DIR = "/var/lib/lxc"
NESTING_MARKER = re.compile(r"^\s*lxc\.apparmor\.allow_nesting\s*=\s*1\s*$", re.M)
KEYCTL_DENY_RULE = re.compile(r"^\s*keyctl\s+errno\s+38\s*$", re.M)


def run(*args):
    """Run a command, returning stdout, or None when it fails."""
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout if out.returncode == 0 else None


def parse_features(line):
    """`nesting=1,keyctl=1` -> {"nesting": "1", "keyctl": "1"}.

    Kept as a dict of key -> value rather than a list of enabled flags, because
    `pct set --features` REPLACES the whole string. Setting `nesting=1,keyctl=1`
    on a container that carries `mount=nfs` would silently drop the mount flag.
    Round-tripping every key is what lets the play merge instead of overwrite.
    """
    features = {}
    for part in (line or "").strip().split(","):
        part = part.strip()
        if not part:
            continue
        key, _, value = part.partition("=")
        features[key.strip()] = value.strip() or "1"
    return features


def declared_features(vmid):
    config = run("pct", "config", str(vmid))
    if config is None:
        return None
    for row in config.splitlines():
        if row.startswith("features:"):
            return parse_features(row.split(":", 1)[1])
    return {}


def running_features(vmid):
    """The features the container is running under, or None when it is stopped.

    ⚠ Returns None rather than {} for a stopped container. The runtime files are
    left behind by the previous run, so reading them after a stop reports the
    features of a container that no longer exists. An empty dict would read as
    "running with nothing enabled" and produce a fix for a problem that is not
    there.
    """
    status = run("pct", "status", str(vmid)) or ""
    if "running" not in status:
        return None

    features = {}

    config_path = os.path.join(LXC_RUNTIME_DIR, str(vmid), "config")
    try:
        with open(config_path, encoding="utf-8", errors="replace") as handle:
            features["nesting"] = "1" if NESTING_MARKER.search(handle.read()) else "0"
    except OSError:
        return None

    # An ABSENT rule means keyctl is allowed. See the header before touching this.
    seccomp_path = os.path.join(LXC_RUNTIME_DIR, str(vmid), "rules.seccomp")
    try:
        with open(seccomp_path, encoding="utf-8", errors="replace") as handle:
            features["keyctl"] = "0" if KEYCTL_DENY_RULE.search(handle.read()) else "1"
    except FileNotFoundError:
        # No seccomp file at all means no rule denying keyctl.
        features["keyctl"] = "1"
    except OSError:
        return None

    return features


def container_ids():
    listing = run("pct", "list")
    if listing is None:
        return []
    ids = []
    for row in listing.splitlines()[1:]:
        first = row.split()
        if first and first[0].isdigit():
            ids.append(int(first[0]))
    return sorted(ids)


def main():
    containers = []
    for vmid in container_ids():
        declared = declared_features(vmid)
        if declared is None:
            # The container vanished between `pct list` and here. Skip it rather
            # than reporting a container with no features, which would read as
            # drift and produce a `pct set` against something that is gone.
            continue

        config = run("pct", "config", str(vmid)) or ""
        hostname = ""
        for row in config.splitlines():
            if row.startswith("hostname:"):
                hostname = row.split(":", 1)[1].strip()
                break

        status = (run("pct", "status", str(vmid)) or "").replace("status:", "").strip()

        containers.append(
            {
                "vmid": vmid,
                "hostname": hostname,
                "status": status or "unknown",
                "declared": declared,
                "running": running_features(vmid),
            }
        )

    json.dump(
        {
            "node": socket.gethostname(),
            "observable": OBSERVABLE,
            "containers": containers,
        },
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
