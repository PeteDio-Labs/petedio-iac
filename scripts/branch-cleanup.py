#!/usr/bin/env python3
"""Delete branches whose tip equals the head of a merged pull request.

    branch-cleanup.py plan   <repo>   # list the safe branches; deletes nothing
    branch-cleanup.py delete <repo>   # re-check each branch, then delete it

<repo> is a repository name under PeteDio-Labs. The script calls `gh api` with GH_TOKEN.

A branch is safe when all of these hold at the moment of the check:
  - it is not the default branch, `main` or `develop`, and GitHub does not protect it;
  - a merged pull request from the same repository used it as head, and the branch tip is
    that pull request's last head commit, so no commit on it is unmerged;
  - no open pull request uses it as head.

`delete` repeats every check against fresh API reads before each delete. Its last line states
what it examined, and it exits non-zero when it examined nothing or any delete failed
(PET-298 and siblings: a green run over no work).
"""
import json
import subprocess
import sys
import urllib.parse

ORG = "PeteDio-Labs"
NEVER = {"main", "develop"}


def gh(path, method="GET"):
    cmd = ["gh", "api", "-X", method, path]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{method} {path}: {(p.stderr or p.stdout).strip()[:200]}")
    return json.loads(p.stdout) if p.stdout.strip() else None


def pages(path):
    out, n = [], 1
    sep = "&" if "?" in path else "?"
    while n <= 100:
        chunk = gh(f"{path}{sep}per_page=100&page={n}")
        out += chunk
        if len(chunk) < 100:
            return out
        n += 1
    raise RuntimeError(f"{path}: more than 100 pages")


def survey(repo):
    """Return (default, branches {name: (sha, protected)}, merged {head ref: set of head shas}, open refs)."""
    base = f"repos/{ORG}/{repo}"
    default = gh(base)["default_branch"]
    branches = {b["name"]: (b["commit"]["sha"], b["protected"]) for b in pages(f"{base}/branches")}
    merged = {}
    for pr in pages(f"{base}/pulls?state=closed"):
        head = pr["head"]
        if pr.get("merged_at") and head.get("repo") and head["repo"]["full_name"] == f"{ORG}/{repo}":
            merged.setdefault(head["ref"], set()).add(head["sha"])
    open_refs = {pr["head"]["ref"] for pr in pages(f"{base}/pulls?state=open")}
    return default, branches, merged, open_refs


def safe_names(default, branches, merged, open_refs):
    safe = []
    for name, (sha, protected) in sorted(branches.items()):
        if name in NEVER or name == default or protected or name in open_refs:
            continue
        if sha in merged.get(name, ()):
            safe.append(name)
    return safe


def main(argv):
    if len(argv) != 3 or argv[1] not in ("plan", "delete") or "/" in argv[2]:
        print(__doc__, file=sys.stderr)
        return 2
    mode, repo = argv[1], argv[2]
    default, branches, merged, open_refs = survey(repo)
    safe = safe_names(default, branches, merged, open_refs)
    print(f"read {len(branches)} branches, {len(merged)} merged head refs, {len(open_refs)} open pull requests in {repo}")
    if not branches or not merged:
        print(f"ABORT: nothing to compare in {repo}; a result built on an empty read is not a result.", file=sys.stderr)
        return 1
    for name in safe:
        print(f"  safe: {name}")
    if mode == "plan":
        print(f"branch-cleanup plan {repo}: examined {len(branches)} branches; {len(safe)} safe; deleted 0")
        return 0
    deleted = refused = failed = 0
    for name in safe:
        try:
            # Fresh reads: the survey can be minutes old.
            fresh = gh(f"repos/{ORG}/{repo}/branches/{urllib.parse.quote(name, safe='')}")
            op = gh(f"repos/{ORG}/{repo}/pulls?state=open&head={ORG}:{urllib.parse.quote(name, safe='')}")
            if fresh["protected"] or op or fresh["commit"]["sha"] not in merged.get(name, ()):
                print(f"  refused: {name} changed since the survey")
                refused += 1
                continue
            gh(f"repos/{ORG}/{repo}/git/refs/heads/{urllib.parse.quote(name, safe='/')}", "DELETE")
            print(f"  deleted: {name} (was {fresh['commit']['sha'][:7]})")
            deleted += 1
        except RuntimeError as e:
            print(f"  FAILED: {name}: {e}", file=sys.stderr)
            failed += 1
    print(f"branch-cleanup delete {repo}: examined {len(branches)} branches; {len(safe)} safe; deleted {deleted}; refused {refused}; failed {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
