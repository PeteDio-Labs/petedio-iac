#!/usr/bin/env python3
"""Report the `startup` line of every LXC on one Proxmox node.

Read-only. It decides nothing: roles/lxc-startup/defaults/main.yml holds the
declaration, and roles/lxc-startup/tasks/plan.yml compares the two.

It reads `pct config <vmid>`, the command in PET-451's verify step, so the play
and a person at the node read the same line. `pct config` encodes the newlines
in `description`, so a line that starts with `startup:` is the option itself.

⚠ NO RESTART-PENDING STATE, UNLIKE lxc-features. pve-container lists `startup`
in $LXC_FASTPLUG_OPTIONS (src/PVE/LXC/Config.pm), so `pct set --startup` writes
the config at once, even while the container runs. The node reads that line
when it next starts or stops its guests, so the line printed here is the one
the node uses.

⚠ A FAILED READ EXITS 1. `pct list` prints nothing at all on a node with no
containers. If a failed call were skipped, a node this script could not read
would report the same empty result as a node with no media guests.

Emits one JSON object on stdout:

  {"node": "pve02",
   "containers": [{"vmid": 236, "hostname": "plex-gpu",
                   "startup": "order=7,up=0,down=15"}, ...]}

`startup` is null for a container with no line. The value passes through
unparsed, so every comparison stays in Jinja, where tests/lxc-startup-plan.yml
runs it.
"""

import json
import socket
import subprocess
import sys


def run(*args):
    """Run a command and return its stdout. Exit 1 when it fails."""
    command = " ".join(args)
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as err:
        sys.exit(f"{command}: {err}")
    if out.returncode != 0:
        sys.exit(f"{command} exited {out.returncode}: {out.stderr.strip()}")
    return out.stdout


def container_ids():
    """VMIDs from `pct list`. Its header row is not a number, so it drops out."""
    ids = []
    for row in run("pct", "list").splitlines():
        fields = row.split()
        if fields and fields[0].isdigit():
            ids.append(int(fields[0]))
    return sorted(ids)


def config_value(config, key):
    """The value of `key:` in `pct config` output, or None when the line is absent."""
    prefix = key + ":"
    for row in config.splitlines():
        if row.startswith(prefix):
            return row[len(prefix):].strip()
    return None


def main():
    containers = []
    for vmid in container_ids():
        config = run("pct", "config", str(vmid))
        containers.append(
            {
                "vmid": vmid,
                "hostname": config_value(config, "hostname") or "",
                "startup": config_value(config, "startup"),
            }
        )

    json.dump(
        {"node": socket.gethostname(), "containers": containers},
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
