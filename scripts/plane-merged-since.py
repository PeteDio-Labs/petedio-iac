#!/usr/bin/env python3
"""Emit `headRefName<TAB>url` for PRs merged on/after a date.

Split out of plane-reconcile.yml deliberately: embedding Python inside a YAML
block scalar inside a shell heredoc is three levels of quoting, and the
indentation rules of all three disagree. A file can also be run by hand.

    python3 scripts/plane-merged-since.py merged.json 2026-08-10

Accepts either payload shape:

  * **REST** (`GET /repos/{repo}/pulls?state=closed`) — what plane-reconcile.yml
    feeds it, since the self-hosted runner has no `gh` binary. Fields are
    `head.ref`, `merged_at`, `html_url`.
  * **`gh pr list --json number,headRefName,mergedAt,url`** — kept working so the
    by-hand path in the docstring above still runs on a laptop that has `gh`.

The shapes are told apart by `head` being a dict, NOT by falling back field by
field: REST payloads also carry a top-level `url`, but it is the *API* URL
(api.github.com/...), so a naive `pr.get("url")` fallback would silently post
api.github.com links into Plane work items instead of browsable PR links.
"""
import json
import sys

if len(sys.argv) != 3:
    sys.exit(f"usage: {sys.argv[0]} <pulls.json> <YYYY-MM-DD>")

path, since = sys.argv[1], sys.argv[2]
with open(path) as fh:
    prs = json.load(fh)

if not isinstance(prs, list):
    sys.exit(f"{path}: expected a JSON array of PRs, got {type(prs).__name__}")

for pr in prs:
    # Both shapes emit RFC-3339; a lexicographic compare on the date prefix is
    # correct and avoids a tz-parsing dependency for a once-a-night job.
    # Closed-but-unmerged PRs have merged_at=null -> "" -> never in window.
    merged_at = pr.get("mergedAt") or pr.get("merged_at") or ""
    if merged_at[:10] < since:
        continue

    if isinstance(pr.get("head"), dict):  # REST
        ref = pr["head"].get("ref") or ""
        url = pr.get("html_url") or ""
    else:  # gh --json
        ref = pr.get("headRefName") or ""
        url = pr.get("url") or ""

    if not ref or not url:
        print(f"skipping PR #{pr.get('number', '?')}: no branch/url", file=sys.stderr)
        continue

    print(f"{ref}\t{url}")
