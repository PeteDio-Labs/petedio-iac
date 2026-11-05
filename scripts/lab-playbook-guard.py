#!/usr/bin/env python3
"""lab-playbook-guard: decide whether lab-action.yml may run a playbook (PET-861).

    scripts/lab-playbook-guard.py <playbook-name>     # exit 0 = allowed, 1 = refused
    scripts/lab-playbook-guard.py --all               # report every playbook, for review

A thread runs `ansible-playbook --check` with no approval, and check mode is only a promise:
a task with `check_mode: false` runs for real. So a playbook is allowed only when:

1. its name is in scripts/lab-playbooks.txt, the reviewed allowlist, and
2. every `check_mode: false` (or `no`) line in its tree carries the marker
   `# lab-action: read-only`, which a reviewer adds after reading that task.

The tree is the playbook file, every playbook it imports, and every role it names, followed to a
fixed point through each role's own files. A role counts when its name appears as a word in any
file already in the tree, which over-includes on purpose: a refusal costs a review, a miss costs
a write nobody approved. It prints the files it examined, so "allowed" never means "read nothing".
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ANSIBLE = ROOT / "ansible"
PLAYBOOKS = ANSIBLE / "playbooks"
ROLES = ANSIBLE / "roles"
ALLOWLIST = ROOT / "scripts" / "lab-playbooks.txt"
MARKER = "# lab-action: read-only"
CHECK_OFF = re.compile(r"^\s*(-\s*)?check_mode:\s*(false|no|False)\b")
NAME = re.compile(r"^[a-z0-9][a-z0-9-]*\.yml$")


def allowlist() -> set[str]:
    names = set()
    for line in ALLOWLIST.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names


def yaml_files(path: pathlib.Path) -> list[pathlib.Path]:
    if path.is_file():
        return [path]
    return sorted(p for p in path.rglob("*") if p.suffix in (".yml", ".yaml") and p.is_file())


def tree(playbook: pathlib.Path) -> list[pathlib.Path]:
    role_names = {p.name for p in ROLES.iterdir() if p.is_dir()}
    files: list[pathlib.Path] = []
    seen_roles: set[str] = set()
    queue = [playbook]
    while queue:
        f = queue.pop()
        if f in files:
            continue
        files.append(f)
        text = f.read_text(errors="replace")
        for m in re.finditer(r"import_playbook:\s*['\"]?([\w./-]+\.yml)", text):
            queue.append((f.parent / m.group(1)).resolve())
        for role in role_names - seen_roles:
            if re.search(rf"(?<![\w-]){re.escape(role)}(?![\w-])", text):
                seen_roles.add(role)
                queue.extend(yaml_files(ROLES / role))
    return files


def unmarked(files: list[pathlib.Path]) -> list[str]:
    bad = []
    for f in files:
        for i, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            if CHECK_OFF.match(line) and MARKER not in line:
                bad.append(f"{f.relative_to(ROOT)}:{i}")
    return bad


def check(name: str, allowed: set[str], quiet: bool = False) -> bool:
    if not NAME.match(name) or not (PLAYBOOKS / name).is_file():
        print(f"REFUSED {name}: not a playbook under ansible/playbooks/")
        return False
    files = tree((PLAYBOOKS / name).resolve())
    bad = unmarked(files)
    listed = name in allowed
    verdict = "ALLOWED" if listed and not bad else "REFUSED"
    why = []
    if not listed:
        why.append("not in scripts/lab-playbooks.txt")
    if bad:
        why.append(f"{len(bad)} unmarked check_mode: false: {', '.join(bad[:5])}")
    print(f"{verdict} {name}: examined {len(files)} files" + (f"; {'; '.join(why)}" if why else ""))
    return verdict == "ALLOWED"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    allowed = allowlist()
    if argv[1] == "--all":
        for p in sorted(PLAYBOOKS.glob("*.yml")):
            check(p.name, allowed)
        return 0
    return 0 if check(argv[1], allowed) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
