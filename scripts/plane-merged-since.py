#!/usr/bin/env python3
"""Emit `headRefName<TAB>url` for PRs merged on/after a date.

Split out of plane-reconcile.yml deliberately: embedding Python inside a YAML
block scalar inside a shell heredoc is three levels of quoting, and the
indentation rules of all three disagree. A file can also be run by hand.

    python3 scripts/plane-merged-since.py merged.json 2026-08-10
"""
import json
import sys

if len(sys.argv) != 3:
    sys.exit(f"usage: {sys.argv[0]} <gh-pr-list.json> <YYYY-MM-DD>")

path, since = sys.argv[1], sys.argv[2]
with open(path) as fh:
    prs = json.load(fh)

for pr in prs:
    merged_at = pr.get("mergedAt") or ""
    # gh emits RFC-3339; a lexicographic compare on the date prefix is correct
    # and avoids a tz-parsing dependency for a once-a-night job.
    if merged_at[:10] >= since:
        print(f"{pr['headRefName']}\t{pr['url']}")
