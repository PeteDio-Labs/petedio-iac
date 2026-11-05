#!/usr/bin/env python3
"""lab-playbook-guard: decide whether lab-action.yml may run a playbook (PET-861).

    scripts/lab-playbook-guard.py <playbook-name>     # exit 0 = allowed, 1 = refused
    scripts/lab-playbook-guard.py --all               # report every playbook, for review

A thread runs `ansible-playbook --check` with no approval, and check mode is only a promise:
a task with `check_mode: false` runs for real. So a playbook is allowed only when:

1. its name is in scripts/lab-playbooks.txt, the reviewed allowlist,
2. every `check_mode` key in its tree whose value is not plain true carries the marker
   `# lab-action: read-only` on that line, which a reviewer adds after reading that task,
3. no task in its tree sets `diff` to anything but false, because a diff prints file contents
   into the public log,
4. every file it includes resolves to a literal path the guard can read, and
5. no Ansible module or plugin code ships in the repo, since that runs for real in a check.

Keys are found by parsing the YAML, not by matching lines, so every spelling of false counts.

The tree is the playbook file, every playbook it imports, and every role it names, followed to a
fixed point through each role's own files. A role counts when its name appears as a word in any
file already in the tree, which over-includes on purpose: a refusal costs a review, a miss costs
a write nobody approved. It prints the files it examined, so "allowed" never means "read nothing".
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ANSIBLE = ROOT / "ansible"
PLAYBOOKS = ANSIBLE / "playbooks"
ROLES = ANSIBLE / "roles"
ALLOWLIST = ROOT / "scripts" / "lab-playbooks.txt"
MARKER = "# lab-action: read-only"
TRUE_WORDS = {"true", "yes", "on"}
FALSE_WORDS = {"false", "no", "off"}
INCLUDE_KEYS = {
    "import_playbook", "ansible.builtin.import_playbook",
    "include_tasks", "ansible.builtin.include_tasks",
    "import_tasks", "ansible.builtin.import_tasks",
    "include_vars", "ansible.builtin.include_vars", "vars_files",
}
CODE_DIRS = ("library", "module_utils", "action_plugins", "filter_plugins", "lookup_plugins",
             "callback_plugins", "connection_plugins", "strategy_plugins", "test_plugins",
             "vars_plugins", "inventory_plugins")
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


def scalars(node):
    """Every scalar value under a YAML node, for include targets given as a list or a dict."""
    if isinstance(node, yaml.ScalarNode):
        yield node
    elif isinstance(node, yaml.SequenceNode):
        for n in node.value:
            yield from scalars(n)
    elif isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            if k.value in ("file", "name", "_raw_params") or isinstance(v, yaml.SequenceNode):
                yield from scalars(v)


def walk(node, out: list):
    """Collect (key, key node, value node) for every mapping entry under node."""
    if isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            if isinstance(k, yaml.ScalarNode):
                out.append((k.value, k, v))
            walk(v, out)
    elif isinstance(node, yaml.SequenceNode):
        for n in node.value:
            walk(n, out)


def entries(f: pathlib.Path) -> list:
    out: list = []
    try:
        for doc in yaml.compose_all(f.read_text(errors="replace"), Loader=yaml.SafeLoader):
            walk(doc, out)
    except yaml.YAMLError as e:
        raise ValueError(f"{f.relative_to(ROOT)} does not parse: {e}") from e
    return out


def plain(v) -> str | None:
    return v.value.strip().lower() if isinstance(v, yaml.ScalarNode) else None


def tree(playbook: pathlib.Path) -> tuple[list[pathlib.Path], list[str]]:
    """The playbook's files, plus the problems found while walking them."""
    role_names = {p.name for p in ROLES.iterdir() if p.is_dir()}
    files: list[pathlib.Path] = []
    problems: list[str] = []
    seen_roles: set[str] = set()
    queue = [playbook]
    while queue:
        f = queue.pop()
        if f in files:
            continue
        files.append(f)
        for key, _, v in entries(f):
            if key not in INCLUDE_KEYS:
                continue
            for target in scalars(v):
                t = target.value
                if "{{" in t or "{%" in t:
                    problems.append(f"{f.relative_to(ROOT)}:{target.start_mark.line + 1} templated {key}")
                    continue
                cand = [(f.parent / t).resolve()] + [(r / t).resolve() for r in (f.parent.parent, PLAYBOOKS)]
                hit = next((c for c in cand if c.is_file()), None)
                if hit is None:
                    problems.append(f"{f.relative_to(ROOT)}:{target.start_mark.line + 1} {key} {t} not found")
                else:
                    queue.append(hit)
        text = f.read_text(errors="replace")
        for role in role_names - seen_roles:
            if re.search(rf"(?<![\w-]){re.escape(role)}(?![\w-])", text):
                seen_roles.add(role)
                queue.extend(yaml_files(ROLES / role))
    for base in [ANSIBLE] + [ROLES / r for r in seen_roles]:
        for d in CODE_DIRS:
            if (base / d).exists():
                problems.append(f"{(base / d).relative_to(ROOT)} holds module or plugin code")
    return files, problems


def unmarked(files: list[pathlib.Path]) -> list[str]:
    bad = []
    for f in files:
        lines = f.read_text(errors="replace").splitlines()
        for key, k, v in entries(f):
            where = f"{f.relative_to(ROOT)}:{k.start_mark.line + 1}"
            line = lines[k.start_mark.line] if k.start_mark.line < len(lines) else ""
            if key == "check_mode" and plain(v) not in TRUE_WORDS and MARKER not in line:
                bad.append(f"{where} check_mode")
            if key == "diff" and plain(v) not in FALSE_WORDS:
                bad.append(f"{where} diff")
    return bad


def check(name: str, allowed: set[str], quiet: bool = False) -> bool:
    if not NAME.fullmatch(name) or not (PLAYBOOKS / name).is_file():
        print(f"REFUSED {name}: not a playbook under ansible/playbooks/")
        return False
    try:
        files, problems = tree((PLAYBOOKS / name).resolve())
        bad = problems + unmarked(files)
    except ValueError as e:
        print(f"REFUSED {name}: {e}")
        return False
    listed = name in allowed
    verdict = "ALLOWED" if listed and not bad else "REFUSED"
    why = []
    if not listed:
        why.append("not in scripts/lab-playbooks.txt")
    if bad:
        why.append(f"{len(bad)} problems: {', '.join(bad[:5])}")
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
