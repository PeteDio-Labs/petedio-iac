#!/usr/bin/env python3
"""GitHub calls for terraform-plan.yml (PET-866), using python3 and urllib.

The homelab runner has no `gh` (plane-reconcile.yml records the exit-127 failure), and python3 is
already required by lab-action.yml. Reads GH_TOKEN and GH_REPO from the environment.

  find-pr    HEAD_SHA PAYLOAD_PR   writes number=, skip= to $GITHUB_OUTPUT
  base-ok    BASE_SHA              exit 0 when main contains BASE_SHA
  head-sha   PR_NUMBER             prints the PR head SHA
  upsert     PR_NUMBER FILE        creates or updates the bot's marked plan comment
"""
import json
import os
import sys
import urllib.request

MARK = "<!-- terraform-plan-comment -->"
LIMIT = 60000  # GitHub rejects a comment body over 65,536 characters.


def api(method, path, body=None):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{os.environ['GH_REPO']}/{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def out(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a") as f:
        f.write(f"{key}={value}\n")


def find_pr(head, payload_pr):
    prs = [p for p in api("GET", f"commits/{head}/pulls") if p["state"] == "open"]
    if not prs:
        if payload_pr:
            print(f"::error::PR {payload_pr} was named by the trigger but no open PR has head {head}")
            return 1
        print(f"No open PR has head {head}: nothing was planned and nothing was examined.")
        out("skip", "true")
        return 0
    n, base = prs[0]["number"], prs[0]["base"]["ref"]
    if base != "main":
        print(f"PR {n} targets {base}, not main: nothing was planned and nothing was examined.")
        out("skip", "true")
        return 0
    out("number", n)
    out("skip", "false")
    return 0


def upsert(n, path):
    body = open(path).read()
    if len(body) > LIMIT:
        body = body[:LIMIT] + "\n\n_Comment cut at the GitHub size limit. Run the plan locally for the rest._"
    body = f"{MARK}\n{body}"
    comments = api("GET", f"issues/{n}/comments?per_page=100")
    mine = [c for c in comments
            if c["user"]["login"] == "github-actions[bot]" and c["body"].startswith(MARK)]
    if mine:
        api("PATCH", f"issues/comments/{mine[0]['id']}", {"body": body})
    else:
        api("POST", f"issues/{n}/comments", {"body": body})
    print(f"Commented on PR {n}.")
    return 0


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "find-pr":
        return find_pr(args[0], args[1] if len(args) > 1 else "")
    if cmd == "base-ok":
        status = api("GET", f"compare/{args[0]}...main")["status"]
        ok = status in ("identical", "ahead")
        print(f"base parent {args[0]} vs main: {status}")
        return 0 if ok else 1
    if cmd == "head-sha":
        print(api("GET", f"pulls/{args[0]}")["head"]["sha"])
        return 0
    if cmd == "upsert":
        return upsert(args[0], args[1])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
