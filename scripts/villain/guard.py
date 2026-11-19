#!/usr/bin/env python3
"""Lab Villains guard (PET-954): choose victims, or refuse, and change nothing.

    scripts/villain/guard.py check joker  [--seed N]
    scripts/villain/guard.py check thanos --group GROUP [--seed N]

It reads scripts/villain/targets.txt and prints what it examined and what it picked. It never
touches a host. The strike playbooks call it first and act only on the victims it prints.

Refusals exit non-zero. An empty allowlist is a refusal, not a clean result.
"""
import argparse
import os
import random
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
TARGETS = HERE / "targets.txt"

# Tiers a villain may hit. Widening this list is a trust-boundary change.
TIERS_ALLOWED = {"decoy"}

# Never hit, even when listed: Vault, Authentik, cloudflared, MinIO, runners, pete-bot,
# Prometheus, Plane shim, Ollama, claude-247 and codex-248. Checked against vault/Hosts/hosts-inventory.md.
DENY_VMIDS = {112, 119, 221, 223, 232, 233, 235, 237, 240, 245, 246, 247, 248}

# pve03's backup job stops guests around 02:45 Eastern.
QUIET_START, QUIET_END = (2, 15), (3, 30)
TZ = ZoneInfo("America/New_York")

JOKER_FAULTS = ("stop", "restart", "kill-service")


class Refused(Exception):
    pass


def read_targets(path):
    rows, lines = [], 0
    for raw in Path(path).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        lines += 1
        parts = line.split()
        if len(parts) != 5 or not parts[1].isdigit():
            raise Refused(f"malformed targets line: {raw!r}")
        group, vmid, name, node, tier = parts
        rows.append({"group": group, "vmid": int(vmid), "name": name, "node": node, "tier": tier})
    return rows


def usable(rows):
    ok, denied = [], []
    for r in rows:
        if r["vmid"] in DENY_VMIDS:
            denied.append((r, "vmid on the denylist"))
        elif r["tier"] not in TIERS_ALLOWED:
            denied.append((r, f"tier {r['tier']} not allowed"))
        else:
            ok.append(r)
    return ok, denied


def in_quiet_hours(now):
    hm = (now.astimezone(TZ).hour, now.astimezone(TZ).minute)
    return QUIET_START <= hm < QUIET_END


def pick(villain, rows, group, seed):
    rng = random.Random(seed)
    ok, denied = usable(rows)
    if not ok:
        raise Refused(f"no usable targets: read {len(rows)}, denied {len(denied)}")
    if villain == "joker":
        victim = rng.choice(ok)
        return [dict(victim, fault=rng.choice(JOKER_FAULTS))], denied
    members = [r for r in ok if r["group"] == group]
    if len(members) < 2:
        raise Refused(f"group {group!r} has {len(members)} usable members; Thanos needs 2 or more")
    k = len(members) // 2  # half, rounded down; never the last member
    return [dict(v, fault="stop") for v in rng.sample(members, k)], denied


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("mode", choices=["check"])
    ap.add_argument("villain", choices=["joker", "thanos"])
    ap.add_argument("--group")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--targets", default=str(TARGETS))
    ap.add_argument("--now", help="ISO time, for tests")
    a = ap.parse_args(argv)
    seed = a.seed if a.seed is not None else random.SystemRandom().randrange(2**32)
    now = datetime.fromisoformat(a.now) if a.now else datetime.now(TZ)
    try:
        rows = read_targets(a.targets)
        if a.villain == "thanos" and not a.group:
            raise Refused("thanos needs --group")
        if in_quiet_hours(now):
            raise Refused("quiet hours: the backup window is 02:15 to 03:30 Eastern")
        victims, denied = pick(a.villain, rows, a.group, seed)
    except Refused as e:
        print(f"villain-guard: REFUSED: {e}", file=sys.stderr)
        return 1
    switch = os.environ.get("VILLAINS_ENABLED", "false")
    print(f"villain-guard: read {len(rows)} targets; denied {len(denied)}; picked {len(victims)}; seed {seed}")
    for v in victims:
        print(f"  victim {v['vmid']} {v['name']} on {v['node']} group {v['group']} fault {v['fault']}")
    print(f"  kill switch VILLAINS_ENABLED={switch}: a strike {'may proceed' if switch == 'true' else 'would be refused'}")
    print("  dry run: nothing was touched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
