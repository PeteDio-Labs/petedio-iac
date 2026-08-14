#!/usr/bin/env python3
"""infra-reconcile — does the vault's host inventory still match the cluster?

WHY THIS EXISTS, and why it is a diff rather than an audit:

  On 2026-08-14 the inventory was measured against reality: 23 guests live, 22
  documented. Exactly one miss — LXC 235, the tracker's own host, built the day
  before. The inventory had been re-verified against `pct list` that same day and
  still missed it. 243 was missed the same way, for months.

  So the inventory does NOT rot. It sits around 96% accurate and stays there.
  Drift enters at CREATION time: a host is built and nothing forces a note to
  exist. That is a boundary problem, and the fix is a detector at the boundary —
  a diff that takes seconds — not a periodic re-audit nobody schedules.

WHAT IT WILL NOT DO: edit the vault. It raises work and stops. A note's value is
its reasoning, which is the one part a machine cannot regenerate; a bot that
rewrites prose to match reality destroys the half worth keeping. Detect, don't
correct.

Advisory, like plane-sync: it exits 0 even when Plane or Proxmox is unreachable.
A nightly job that goes red because Vault was sealed is noise, not signal.

  ./scripts/infra-reconcile.py --vault ~/petedio/vault [--dry-run]

Env: PROXMOX_ENDPOINT, PROXMOX_API_TOKEN
     PLANE_BASE_URL, PLANE_WORKSPACE, PLANE_PROJECT_ID, PLANE_API_KEY
"""

import argparse
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

SOURCE = "infra-reconcile"  # external_source stamped on every item we mint

DIM, OFF, RED, YEL, GRN = "\033[2m", "\033[0m", "\033[31m", "\033[33m", "\033[32m"


def _get(url, headers, insecure=False):
    ctx = ssl._create_unverified_context() if insecure else None
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
        return json.load(r)


def _items(resp):
    """Plane answers list endpoints in THREE shapes. Absorb that here, once.

      1. bare list                      — `/states/`
      2. paginated object with results  — `/issues/?per_page=…`
      3. a single bare object           — `/issues/?external_id=…`, which returns
                                          the matching item itself, unwrapped

    Shape 2 iterated blind yields dict KEYS, surfacing far from the cause as
    `'str' object has no attribute 'get'`. Shape 3 is the nastier one: it looks
    like shape 2 with no results, so a lookup silently reports "not found" and
    the caller creates a duplicate — which Plane then rejects with a 409, making
    a working uniqueness guarantee look like a failure.
    """
    if isinstance(resp, list):
        return resp
    if isinstance(resp, dict):
        if "results" in resp:
            return resp["results"] or []
        if resp.get("id"):  # shape 3 — a single unwrapped object
            return [resp]
    return []


def _post(url, headers, payload):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body, headers={**headers, "Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


# ---------------------------------------------------------------- live cluster

def live_guests(endpoint, token):
    """Every guest on every node, in one call.

    /cluster/resources is deliberate: querying each node separately means a node
    that is merely unreachable looks exactly like a node whose guests were all
    destroyed, and that is the one mistake that would make this tool dangerous.
    """
    url = f"{endpoint.rstrip('/')}/api2/json/cluster/resources?type=vm"
    data = _get(url, {"Authorization": f"PVEAPIToken={token}"}, insecure=True)["data"]
    return {
        int(g["vmid"]): {
            "name": g.get("name", "?"),
            "node": g.get("node", "?"),
            "status": g.get("status", "?"),
            "type": g.get("type", "?"),
        }
        for g in data or []
    }


# ------------------------------------------------------------- documented side

def documented_guests(vault_path):
    """Host notes that CLAIM to be a live guest.

    The filter is `vmid:` AND `status: live`, and both halves earned their place:
      - no vmid  -> 012-ollama-host (bare metal), pve01/pve02 (the nodes
        themselves), hosts-inventory. None are guests; none should be compared.
      - retired  -> 234-palworld still carries vmid 234 as history. Comparing it
        would report a ghost every single night, and a detector that cries wolf
        gets muted, which is worse than not having one.
    """
    hosts = os.path.join(vault_path, "Hosts")
    out = {}
    for fn in sorted(os.listdir(hosts)):
        if not fn.endswith(".md"):
            continue
        text = open(os.path.join(hosts, fn), encoding="utf-8").read()
        m = re.match(r"^---\n(.*?)\n---", text, re.S)
        if not m:
            continue
        fm = dict(re.findall(r"^(\w+):\s*(.+?)\s*$", m.group(1), re.M))
        if "vmid" not in fm or fm.get("status") != "live":
            continue
        try:
            out[int(fm["vmid"])] = {"file": fn, "node": fm.get("node", "?"), "host": fm.get("host", "?")}
        except ValueError:
            continue
    return out


# --------------------------------------------------------------------- diffing

def diff(live, documented):
    drifts = []
    for vmid in sorted(set(live) - set(documented)):
        g = live[vmid]
        drifts.append({
            "key": f"vmid-{vmid}-undocumented",
            "title": f"VMID {vmid} ({g['name']}) is live but has no vault host note",
            "detail": (
                f"<p><code>{g['type']}</code> <strong>{g['name']}</strong> is running on "
                f"<code>{g['node']}</code>, and no note in <code>Hosts/</code> declares "
                f"<code>vmid: {vmid}</code> with <code>status: live</code>.</p>"
                f"<p>This is the creation-time drift class: the host exists, and nothing "
                f"forced a note to exist with it. Write <code>Hosts/{vmid}-&lt;name&gt;.md</code> "
                f"and add the row to <code>hosts-inventory</code>.</p>"
            ),
        })
    for vmid in sorted(set(documented) - set(live)):
        d = documented[vmid]
        drifts.append({
            "key": f"vmid-{vmid}-ghost",
            "title": f"VMID {vmid} ({d['host']}) is documented live but is not on the cluster",
            "detail": (
                f"<p><code>{d['file']}</code> declares <code>status: live</code>, but no guest "
                f"with VMID {vmid} exists on any node.</p>"
                f"<p>Either it was destroyed and the note needs <code>status: retired</code>, or "
                f"something is down that should not be. <strong>Check which before editing the "
                f"note</strong> — this is exactly the shape of the stale Linear inventory that "
                f"listed dead hosts as live for months.</p>"
            ),
        })
    for vmid in sorted(set(live) & set(documented)):
        want, got = documented[vmid]["node"], live[vmid]["node"]
        if want not in ("?", got):
            drifts.append({
                "key": f"vmid-{vmid}-node",
                "title": f"VMID {vmid} ({live[vmid]['name']}) is on {got}, note says {want}",
                "detail": (
                    f"<p><code>{documented[vmid]['file']}</code> has <code>node: {want}</code>; "
                    f"the cluster reports <code>{got}</code>. A migration that never reached "
                    f"the note.</p>"
                ),
            })
    return drifts


# ----------------------------------------------------------------------- plane

class Plane:
    def __init__(self, base, workspace, project, key):
        self.p = f"{base.rstrip('/')}/api/v1/workspaces/{workspace}/projects/{project}"
        self.h = {"X-API-Key": key}

    def existing(self, key):
        """Has this exact drift already been raised?

        external_id is what makes a nightly job safe to run nightly: persistent
        drift updates nothing instead of minting a new work item every morning.
        """
        q = urllib.parse.urlencode({"external_id": key, "external_source": SOURCE})
        try:
            return (_items(_get(f"{self.p}/issues/?{q}", self.h)) or [None])[0]
        except urllib.error.HTTPError:
            return None

    def todo_state(self):
        for s in _items(_get(f"{self.p}/states/", self.h)):
            if s.get("name") == "Todo":
                return s["id"]
        return None

    def create(self, drift, state):
        return _post(f"{self.p}/issues/", self.h, {
            "name": drift["title"],
            "description_html": drift["detail"] + (
                "<p><em>Raised automatically by <code>infra-reconcile</code>. It detects and "
                "never edits the vault — the reasoning in a note is the part a machine cannot "
                "regenerate.</em></p>"
            ),
            "state": state,
            "priority": "medium",
            "external_source": SOURCE,
            "external_id": drift["key"],
        })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", default=os.environ.get("VAULT_PATH", "../vault"))
    ap.add_argument("--dry-run", action="store_true", help="diff and print; touch nothing")
    args = ap.parse_args()

    endpoint = os.environ.get("PROXMOX_ENDPOINT", "https://192.168.50.10:8006")
    token = os.environ.get("PROXMOX_API_TOKEN", "")
    if not token:
        print("::warning title=infra-reconcile::No PROXMOX_API_TOKEN — nothing checked.")
        return 0

    if not os.path.isdir(os.path.join(args.vault, "Hosts")):
        print(f"::warning title=infra-reconcile::No vault at {args.vault} — nothing checked.")
        return 0

    try:
        live = live_guests(endpoint, token)
    except Exception as e:
        print(f"::warning title=infra-reconcile::Proxmox unreachable ({e}) — nothing checked.")
        return 0

    documented = documented_guests(args.vault)
    print(f"\n{DIM}cluster{OFF} {len(live)} guests   {DIM}vault{OFF} {len(documented)} documented live\n")

    drifts = diff(live, documented)
    if not drifts:
        print(f"{GRN}✓ no drift{OFF} — every live guest has a note, every note has a guest.\n")
        return 0

    for d in drifts:
        print(f"{YEL}drift{OFF} {d['key']}\n      {d['title']}")

    if args.dry_run:
        print(f"\n{DIM}--dry-run: nothing written to Plane{OFF}\n")
        return 0

    need = ("PLANE_BASE_URL", "PLANE_WORKSPACE", "PLANE_PROJECT_ID", "PLANE_API_KEY")
    if any(not os.environ.get(k) for k in need):
        print(f"\n::warning title=infra-reconcile::{len(drifts)} drift(s) found but Plane is not configured.")
        return 0

    plane = Plane(*(os.environ[k] for k in need))
    # Say WHICH failure this is. plane-bootstrap once blamed a missing workspace for
    # bad-token, bad-slug and nothing-answered alike, and that cost two needless token
    # regenerations during the cutover. Unreachable, refused and malformed are three
    # different problems with three different fixes.
    try:
        state = plane.todo_state()
    except urllib.error.HTTPError as e:
        print(f"\n::warning title=infra-reconcile::Plane refused the request ({e.code}) — "
              f"check the PAT, not the network. {len(drifts)} drift(s) unreported.")
        return 0
    except urllib.error.URLError as e:
        print(f"\n::warning title=infra-reconcile::Plane unreachable ({e.reason}) — "
              f"{len(drifts)} drift(s) unreported; tomorrow's run will retry.")
        return 0
    except Exception as e:
        print(f"\n::warning title=infra-reconcile::Plane answered something unexpected ({e}) — "
              f"this is a bug here, not an outage. {len(drifts)} drift(s) unreported.")
        return 0
    if not state:
        print("\n::warning title=infra-reconcile::No 'Todo' state on the project — cannot file drift.")
        return 0

    print()
    for d in drifts:
        try:
            if plane.existing(d["key"]):
                print(f"{DIM}already tracked{OFF}  {d['key']}")
                continue
            item = plane.create(d, state)
            print(f"{RED}raised{OFF} PET-{item.get('sequence_id')}  {d['key']}")
        except urllib.error.HTTPError as e:
            # Plane enforces external_id uniqueness itself, so a 409 means the item
            # already exists — the outcome we wanted. Belt and braces behind the
            # lookup above: reporting it as an error would train everyone to ignore
            # this job's warnings, which is how a detector dies.
            if e.code == 409:
                print(f"{DIM}already tracked{OFF}  {d['key']} {DIM}(409){OFF}")
            else:
                print(f"::warning title=infra-reconcile::could not raise {d['key']}: {e}")
        except Exception as e:
            print(f"::warning title=infra-reconcile::could not raise {d['key']}: {e}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
