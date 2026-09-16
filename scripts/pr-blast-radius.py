#!/usr/bin/env python3
"""pr-blast-radius.py — classify a change by what it can do on merge.

Review attention is finite, and it was being spent evenly across changes whose
blast radius differs by orders of magnitude. On 2026-09-16 thirteen open PRs
were waiting on the sole merger; none of them produced a non-empty Terraform
plan, and four of them edited the trust boundary. Nobody could see which was
which without reading all thirteen (PET-463).

This answers "what can this change do when it merges?" from the diff alone. It
runs on a GitHub-hosted runner with no Vault token, no LAN route and no state
access, so it cannot reopen the PET-104 split.

    tier-0  cannot change desired state or a trust boundary
    tier-1  changes host config or tooling, but nothing runs on merge
    tier-2  runs on merge, mints credentials, or moves the trust boundary

The highest tier of any changed path is the tier of the change, and a path the
classifier does not recognise is tier-2. It fails closed: a new kind of file is
something to look at, not something to wave through.

Usage:
    scripts/pr-blast-radius.py                          # this branch vs origin/main
    scripts/pr-blast-radius.py --pr 328                 # a PR in this repo
    scripts/pr-blast-radius.py --pr 57 --repo PeteDio-Labs/petedio-media-iac
    scripts/pr-blast-radius.py --paths a/b.md c/d.tf    # classify a path list
    scripts/pr-blast-radius.py --pr 328 --json          # machine-readable

Exit status is 0 whatever the tier. The tier is the output, not a verdict —
`--fail-above N` turns it into a gate when a caller wants one.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:  # pragma: no cover - the workflow installs it
    sys.exit("pr-blast-radius: PyYAML is required (pip install pyyaml).")


# ---------------------------------------------------------------------------
# Path rules
#
# Ordered most dangerous first; the first pattern a path matches decides it.
# Every pattern is matched against the repo-relative path with fnmatch, where
# `**/` is normalised to match at any depth including zero.
# ---------------------------------------------------------------------------

TIER2_PATTERNS = [
    # The trust boundary itself. A workflow edit decides what runs on which
    # runner holding which credential; it is the single most consequential file
    # class in these repos and the one PET-460 was opened for.
    (".github/**", "edits the trust boundary (workflow or action definition)"),
    # Vault roles, policies and auth mounts.
    ("vault-config/**", "changes Vault roles, policies or auth"),
    # Terraform inputs and state are content-sensitive in ways a comment test
    # cannot clear.
    ("**/*.tfvars", "changes Terraform inputs"),
    ("**/*.tfvars.json", "changes Terraform inputs"),
    ("**/*.tfstate", "touches Terraform state"),
    ("**/*.tfstate.backup", "touches Terraform state"),
    ("**/.terraform.lock.hcl", "changes provider pinning"),
]

TIER1_PATTERNS = [
    ("ansible/**", "changes host configuration; nothing runs until a playbook is run"),
    ("scripts/**", "changes tooling; nothing runs it on merge"),
    ("**/*.sh", "changes tooling; nothing runs it on merge"),
    ("**/*.py", "changes tooling; nothing runs it on merge"),
    ("tests/**", "changes tests"),
    ("**/Makefile", "changes tooling"),
]

TIER0_PATTERNS = [
    ("**/*.md", "prose"),
    ("docs/**", "prose"),
    (".agent/**", "agent-operational notes"),
    ("PET-LOG.md", "the ledger"),
    (".gitignore", "ignore rules"),
    (".gitattributes", "attribute rules"),
    ("LICENSE", "licence text"),
    ("**/*.txt", "plain text"),
    ("**/*.png", "image asset"),
    ("**/*.jpg", "image asset"),
    ("**/*.jpeg", "image asset"),
    ("**/*.gif", "image asset"),
    ("**/*.svg", "image asset"),
    ("**/*.webp", "image asset"),
    ("**/*.pdf", "document asset"),
]

TF_SUFFIXES = (".tf", ".tf.json")

# Flags that make an `ansible-playbook` invocation read-only. If every
# invocation a workflow can reach carries one of these, merging cannot change a
# host through it.
ANSIBLE_READ_ONLY_FLAGS = ("--check", "--syntax-check", "--list-hosts", "--list-tasks", "--list-tags")

TIER_NAMES = {0: "tier-0", 1: "tier-1", 2: "tier-2"}
TIER_BLURB = {
    0: "cannot change desired state or a trust boundary",
    1: "changes host config or tooling, but nothing runs on merge",
    2: "runs on merge, mints credentials, or moves the trust boundary",
}


def match(path: str, pattern: str) -> bool:
    """fnmatch, with `**/` also matching zero directories.

    fnmatch treats `*` as matching separators too, so `docs/**` already matches
    `docs/a/b.md`. The case this adds is `**/*.md` against a top-level
    `README.md`, which fnmatch alone misses because it wants at least the `/`.
    """
    if fnmatch.fnmatch(path, pattern):
        return True
    if pattern.startswith("**/"):
        return fnmatch.fnmatch(path, pattern[3:])
    return False


def match_any(path: str, rules) -> str | None:
    for pattern, reason in rules:
        if match(path, pattern):
            return reason
    return None


# ---------------------------------------------------------------------------
# The live-apply set
#
# DERIVED, NEVER WRITTEN DOWN. `.github/workflows/ansible-palworld.yml`
# triggers on push to main for six ansible paths and reaches
# `ansible-playbook -i inventory/ playbooks/configure-palworld.yml` on the
# self-hosted homelab runner, with no --check. Merging one of those six paths
# runs a playbook against a live host with no operator go, which is PET-442
# arriving through automation rather than by decision.
#
# A hardcoded list of those six paths would be correct today and wrong the
# first time somebody adds another auto-apply workflow — and wrong invisibly,
# which is the failure shape terraform.yml's own `paths-ignore` comment argues
# against. So read it out of the workflows every time.
# ---------------------------------------------------------------------------


def _reachable_workflow_files(root: str, start: str, seen: set[str] | None = None) -> list[str]:
    """`start` plus every local reusable workflow it calls, transitively."""
    seen = seen if seen is not None else set()
    if start in seen or not os.path.isfile(start):
        return []
    seen.add(start)
    files = [start]
    try:
        doc = yaml.safe_load(open(start, encoding="utf-8")) or {}
    except yaml.YAMLError:
        return files
    for job in (doc.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        uses = job.get("uses")
        if isinstance(uses, str) and uses.startswith("./"):
            files += _reachable_workflow_files(root, os.path.join(root, uses[2:]), seen)
    return files


def _runs_self_hosted(root: str, files: list[str]) -> bool:
    for f in files:
        try:
            doc = yaml.safe_load(open(f, encoding="utf-8")) or {}
        except yaml.YAMLError:
            return True  # unparseable: assume the worst
        for job in (doc.get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            runs_on = job.get("runs-on")
            blob = json.dumps(runs_on) if runs_on is not None else ""
            if "self-hosted" in blob:
                return True
    return False


def _runs_live_ansible(files: list[str]) -> bool:
    """True when any reachable file runs ansible-playbook for real.

    Text scan rather than a parse: the command sits inside a shell `run:` block,
    often inside a `docker run ... bash -c "..."`, so there is no structured
    field to read. Conservative on purpose — an invocation is read-only only
    when its own line says so.
    """
    for f in files:
        try:
            text = open(f, encoding="utf-8").read()
        except OSError:
            continue
        for line in text.splitlines():
            if "ansible-playbook" not in line:
                continue
            if any(flag in line for flag in ANSIBLE_READ_ONLY_FLAGS):
                continue
            return True
    return False


def derive_live_apply(root: str) -> tuple[list[tuple[str, str]], list[str]]:
    """Returns (live-apply patterns, names of unfiltered self-hosted workflows).

    A push-triggered workflow that reaches a real `ansible-playbook` on a
    self-hosted runner contributes its `on.push.paths` to the live-apply set.

    A workflow like that with NO `paths:` filter triggers on every merge, so
    naming its paths would mark the whole repo tier-2 and make the classifier
    useless. Those are returned separately and raise the repo's floor to tier-1
    instead: nothing in such a repo auto-merges without a human skim.
    """
    wf_dir = os.path.join(root, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        return [], []

    patterns: list[tuple[str, str]] = []
    unfiltered: list[str] = []

    for name in sorted(os.listdir(wf_dir)):
        if not name.endswith((".yml", ".yaml")):
            continue
        path = os.path.join(wf_dir, name)
        try:
            doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue

        # PyYAML resolves the bare key `on` to the boolean True (YAML 1.1).
        triggers = doc.get("on", doc.get(True)) or {}
        if not isinstance(triggers, dict):
            continue
        push = triggers.get("push")
        if push is None:
            continue
        push = push if isinstance(push, dict) else {}

        files = _reachable_workflow_files(root, path)
        if not (_runs_self_hosted(root, files) and _runs_live_ansible(files)):
            continue

        paths = push.get("paths")
        if not paths:
            unfiltered.append(name)
            continue
        for p in paths:
            patterns.append((p, f"merging this runs a live playbook via .github/workflows/{name}"))

    return patterns, unfiltered


# ---------------------------------------------------------------------------
# The comment-only Terraform test
#
# A .tf file whose changed lines are all comments cannot move the plan. Without
# this test every docs-tidying PR that touches modules/ sits in tier-2 forever,
# which is how media-iac #57 — comments only, in two .tf files — ended up
# queued behind the same review as a workflow edit.
# ---------------------------------------------------------------------------


def split_diff_by_file(diff_text: str) -> dict[str, str]:
    """Map each path in a unified diff to its own hunk text.

    Keyed off `diff --git a/<path> b/<path>` rather than the `+++ b/` line,
    because a deleted file's `+++` reads `/dev/null` and would otherwise
    append that file's hunks to whichever file came before it.
    """
    per_file: dict[str, str] = {}
    current: str | None = None
    buf: list[str] = []
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            if current is not None:
                per_file[current] = "\n".join(buf)
            buf = []
            parts = line.split(" b/", 1)
            current = parts[1] if len(parts) == 2 else None
        elif current is not None:
            buf.append(line)
    if current is not None:
        per_file[current] = "\n".join(buf)
    return per_file


def tf_changes_are_comment_only(diff_text: str) -> bool:
    for line in diff_text.splitlines():
        if line.startswith(("+++", "---", "diff ", "index ", "@@", "new file", "deleted file",
                            "similarity ", "rename ", "old mode", "new mode", "Binary ")):
            continue
        if not line or line[0] not in "+-":
            continue
        body = line[1:].strip()
        if not body or body.startswith("#") or body.startswith("//"):
            continue
        return False
    return True


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------


def classify_path(path: str, live_apply, tf_comment_only: dict[str, bool]) -> tuple[int, str]:
    reason = match_any(path, TIER2_PATTERNS)
    if reason:
        return 2, reason

    reason = match_any(path, live_apply)
    if reason:
        return 2, reason

    if path.endswith(TF_SUFFIXES):
        if tf_comment_only.get(path):
            return 1, "Terraform, comments only — the plan cannot move"
        return 2, "changes Terraform resources"

    reason = match_any(path, TIER1_PATTERNS)
    if reason:
        return 1, reason

    reason = match_any(path, TIER0_PATTERNS)
    if reason:
        return 0, reason

    return 2, "unrecognised path — classified tier-2 because the rules fail closed"


def classify(paths, live_apply, unfiltered, tf_comment_only):
    rows = [(p, *classify_path(p, live_apply, tf_comment_only)) for p in sorted(paths)]
    tier = max((t for _, t, _ in rows), default=0)
    floor_note = None
    if unfiltered and tier < 1:
        tier = 1
        floor_note = (
            "floor raised to tier-1: "
            + ", ".join(unfiltered)
            + " runs a live playbook on a self-hosted runner for every merge, with no paths filter"
        )
    return tier, rows, floor_note


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------


def sh(cmd: list[str], cwd: str | None = None) -> str:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout


def fetch_workflows(repo: str, ref: str) -> str:
    """Download a remote repo's workflow files so the live-apply set can be derived."""
    tmp = tempfile.mkdtemp(prefix="blast-radius-")
    wf_dir = os.path.join(tmp, ".github", "workflows")
    os.makedirs(wf_dir, exist_ok=True)
    try:
        listing = json.loads(sh(["gh", "api", f"repos/{repo}/contents/.github/workflows?ref={ref}"]))
    except subprocess.CalledProcessError:
        return tmp  # no workflows directory on that ref
    for entry in listing:
        if entry.get("type") != "file" or not entry["name"].endswith((".yml", ".yaml")):
            continue
        body = sh(["gh", "api", f"repos/{repo}/contents/{entry['path']}?ref={ref}",
                   "-H", "Accept: application/vnd.github.raw"])
        open(os.path.join(wf_dir, entry["name"]), "w", encoding="utf-8").write(body)
    return tmp


def main() -> int:
    ap = argparse.ArgumentParser(description="Classify a change by what it can do on merge.")
    ap.add_argument("--pr", type=int, help="classify a pull request instead of the working branch")
    ap.add_argument("--repo", help="owner/repo for --pr (default: the repo you are in)")
    ap.add_argument("--paths", nargs="+", help="classify this literal path list")
    ap.add_argument("--paths-from", help="classify the paths in this file, one per line")
    ap.add_argument("--base", default="origin/main", help="base ref for the local diff")
    ap.add_argument("--repo-root", help="repo whose workflows define the live-apply set")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    ap.add_argument("--fail-above", type=int, metavar="N",
                    help="exit 1 when the tier exceeds N (turns this into a gate)")
    args = ap.parse_args()

    root = args.repo_root
    tf_comment_only: dict[str, bool] = {}
    remote_root = None

    # --- gather the changed paths, and the .tf diffs needed to judge them ----
    if args.paths or args.paths_from:
        paths = args.paths or [
            l.strip() for l in open(args.paths_from, encoding="utf-8") if l.strip()
        ]
        root = root or sh(["git", "rev-parse", "--show-toplevel"]).strip()
        for p in (p for p in paths if p.endswith(TF_SUFFIXES)):
            tf_comment_only[p] = False  # no diff supplied: assume it moves the plan
    elif args.pr:
        repo_args = ["-R", args.repo] if args.repo else []
        meta = json.loads(sh(["gh", "pr", "view", str(args.pr), *repo_args,
                              "--json", "files,baseRefName,headRefName,title"]))
        paths = [f["path"] for f in meta["files"]]
        tf_paths = [p for p in paths if p.endswith(TF_SUFFIXES)]
        if tf_paths:
            # `gh pr diff` accepts no pathspec — passing one fails the command
            # and prints nothing, which reads exactly like "no changes here".
            # Take the whole diff and split it locally instead.
            per_file = split_diff_by_file(sh(["gh", "pr", "diff", str(args.pr), *repo_args]))
            for p in tf_paths:
                hunks = per_file.get(p)
                # A .tf file the diff does not mention is not evidence of
                # anything. Assume it moves the plan.
                tf_comment_only[p] = (
                    tf_changes_are_comment_only(hunks) if hunks is not None else False
                )
        if args.repo:
            remote_root = fetch_workflows(args.repo, meta["baseRefName"])
            root = root or remote_root
        root = root or sh(["git", "rev-parse", "--show-toplevel"]).strip()
    else:
        root = root or sh(["git", "rev-parse", "--show-toplevel"]).strip()
        paths = [l for l in sh(["git", "diff", "--name-only", f"{args.base}...HEAD"],
                               cwd=root).splitlines() if l]
        for p in (p for p in paths if p.endswith(TF_SUFFIXES)):
            tf_comment_only[p] = tf_changes_are_comment_only(
                sh(["git", "diff", f"{args.base}...HEAD", "--", p], cwd=root))

    if not paths:
        print("No changed paths. Nothing to classify.")
        return 0

    live_apply, unfiltered = derive_live_apply(root)
    tier, rows, floor_note = classify(paths, live_apply, unfiltered, tf_comment_only)

    if args.json:
        print(json.dumps({
            "tier": tier,
            "tier_name": TIER_NAMES[tier],
            "summary": TIER_BLURB[tier],
            "floor_note": floor_note,
            "live_apply_patterns": [p for p, _ in live_apply],
            "paths": [{"path": p, "tier": t, "reason": r} for p, t, r in rows],
        }, indent=2))
    else:
        width = max(len(p) for p, _, _ in rows)
        print(f"{TIER_NAMES[tier]} — {TIER_BLURB[tier]}")
        print()
        for p, t, r in rows:
            print(f"  {TIER_NAMES[t]}  {p:<{width}}  {r}")
        if floor_note:
            print()
            print(f"  note: {floor_note}")
        if live_apply:
            print()
            print("  live-apply paths derived from this repo's workflows:")
            for p, _ in live_apply:
                print(f"    {p}")

    if args.fail_above is not None and tier > args.fail_above:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
