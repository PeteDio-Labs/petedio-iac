#!/usr/bin/env python3
"""cf-access-logs.py — summarise Cloudflare Access authentication logs for one time window.

Runs from .github/workflows/cf-access-logs.yml, so its output lands in a PUBLIC run log. It
therefore prints only: the app hostname, the action, whether it was allowed, the identity
provider's name and the timestamp. It never prints an email, an IP address, a country, a ray
id or a user id, and it never prints the token or an API response body.

It says what it examined: how many records it read, from which time to which, and whether the
page limit cut the read short. A zero from an empty read is not a result, so an empty window
exits 1.

Usage: cf-access-logs.py --since 2026-11-18T05:30:00Z --until 2026-11-18T07:00:00Z [--app mcp]

Needs: VAULT_ADDR, VAULT_CACERT, VAULT_TOKEN (the cf-logs-read role). Standard library only.
"""
import argparse
import collections
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

SECRET_PATH = "kv/data/services/cloudflare-logs"
CF_API = "https://api.cloudflare.com/client/v4"
LIMIT = 1000
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
APP = re.compile(r"^[a-z0-9.-]{0,60}$")
MAX_LISTED = 60


def die(msg, code=1):
    print(f"FAILED: {msg}", file=sys.stderr)
    sys.exit(code)


def vault_secret():
    for v in ("VAULT_ADDR", "VAULT_CACERT", "VAULT_TOKEN"):
        if not os.environ.get(v):
            die(f"{v} is not set, so nothing was examined.")
    ctx = ssl.create_default_context(cafile=os.environ["VAULT_CACERT"])
    req = urllib.request.Request(
        f"{os.environ['VAULT_ADDR']}/v1/{SECRET_PATH}",
        headers={"X-Vault-Token": os.environ["VAULT_TOKEN"]},
    )
    try:
        with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
            data = json.load(r)["data"]["data"]
    except urllib.error.HTTPError as e:
        die(f"Vault answered {e.code} for {SECRET_PATH}. Run scripts/seed-cloudflare-logs.sh and scripts/apply-vault-config.sh.")
    except Exception as e:  # noqa: BLE001 - report the class only, never a message that might echo a value
        die(f"Vault read failed ({type(e).__name__}).")
    if not data.get("api_token") or not re.fullmatch(r"[0-9a-f]{32}", data.get("account_id", "")):
        die(f"{SECRET_PATH} lacks api_token or a 32-hex account_id.")
    return data["api_token"], data["account_id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", required=True)
    ap.add_argument("--app", default="")
    a = ap.parse_args()
    if not (ISO.match(a.since) and ISO.match(a.until) and a.since < a.until):
        die("since and until must be UTC like 2026-11-18T05:30:00Z, with since before until.", 2)
    if not APP.match(a.app):
        die("app must be a hostname fragment of lowercase letters, digits, dots and hyphens.", 2)

    token, account = vault_secret()
    q = urllib.parse.urlencode({"since": a.since, "until": a.until, "limit": LIMIT, "direction": "asc"})
    req = urllib.request.Request(
        f"{CF_API}/accounts/{account}/access/logs/access_requests?{q}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        die(f"Cloudflare answered HTTP {e.code} for the log read.")
    except Exception as e:  # noqa: BLE001
        die(f"Cloudflare read failed ({type(e).__name__}).")
    if not body.get("success"):
        die("Cloudflare reported success=false for the log read.")
    rows = body.get("result")
    if not isinstance(rows, list):
        die("Cloudflare returned no result list, so nothing was examined.")

    read = len(rows)
    rows = [r for r in rows if a.app in (r.get("app_domain") or "")]
    print(f"examined: read {read} records from {a.since} to {a.until}; "
          f"{len(rows)} match app '{a.app or '*'}'; page limit {LIMIT}"
          f"{' REACHED, so the window is cut short; narrow it' if read >= LIMIT else ''}.")
    if read == 0:
        die("The window holds no records. Widen it, or check the token's account.")

    counts = collections.Counter(
        (r.get("app_domain", "?"), r.get("action", "?"), bool(r.get("allowed"))) for r in rows
    )
    print("\ncount  allowed  action            app")
    for (app, action, allowed), n in sorted(counts.items(), key=lambda kv: (kv[0][0], -kv[1])):
        print(f"{n:5d}  {str(allowed):7s}  {action:16s}  {app}")

    bad = [r for r in rows if not r.get("allowed")]
    print(f"\nnot allowed: {len(bad)} (first {min(len(bad), MAX_LISTED)} shown, oldest first)")
    for r in bad[:MAX_LISTED]:
        print(f"{r.get('created_at', '?')}  {r.get('action', '?'):16s}  {r.get('app_domain', '?')}  idp={r.get('connection', '?')}")

    if rows:
        print(f"\nfirst record {rows[0].get('created_at', '?')}, last {rows[-1].get('created_at', '?')}")


if __name__ == "__main__":
    main()
