#!/usr/bin/env python3
"""playbook-move: move playbooks into area folders and repair every reference (PET-961).

    scripts/playbook-move.py <map-file>            # dry run: print what would change
    scripts/playbook-move.py <map-file> --apply    # git mv the files and rewrite references

The map file holds one move per line: `<file>.yml <area>`. A `#` starts a comment. The area is a
folder under ansible/playbooks/, as docs/playbooks-layout.md defines. Examples:

    backup-audit.yml backup
    configure-mesh-vxlan.yml archive

The script does what a move needs and a plain `git mv` leaves broken:

1. `import_playbook` targets become paths relative to the importing file's new folder.
2. In a moved playbook, `playbook_dir ~ '/../x'` and `{{ playbook_dir }}/../x` gain one `..`,
   and a relative asset (`src: files/x`, `src: templates/x`, a bare `src: x.j2` that exists in
   either folder, or `lookup('file', 'x')` for a file in `files/`) points at the shared folders through `{{ playbook_dir | dirname }}`, which ansible-lint's
   `no-relative-paths` rule accepts and a `../` path does not.
3. Every other text file in the repo (workflows, scripts, docs, inventory, allowlist) that names
   `playbooks/<file>.yml` or a bare `<file>.yml` gets the new path.

It prints how many files it read, moved and rewrote, and exits non-zero when a map line names a
playbook that does not exist or an area that is not a single folder name. It lists any loop-built
`src: "{{ item }}"` it cannot rewrite, for a person to fix. It does not run
Ansible: run `ansible-playbook --syntax-check` over every playbook and
`scripts/lab-playbook-guard.py --all` afterwards.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLAYBOOKS = ROOT / "ansible" / "playbooks"
AREA = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TEXT_SUFFIXES = {".yml", ".tfvars", ".yaml", ".md", ".sh", ".py", ".tf", ".j2", ".toml", ".txt", ".json", ".hcl", ""}
# Files that describe the move and must keep the old names.
SKIP = {"docs/playbooks-layout.md", "scripts/playbook-move.py"}
BARE_SRC = re.compile(r"""(\bsrc:\s*)([A-Za-z0-9][\w.-]*)\s*$""")
FILE_LOOKUP = re.compile(r"""(lookup\('(?:ansible\.builtin\.)?file',\s*)'([A-Za-z0-9][\w.-]*)'""")
# A loop-built `src: "{{ item }}.j2"` names an asset the script cannot see. A person rewrites it.
TEMPLATED_SRC = re.compile(r"""\bsrc:\s*["']?\{\{\s*item\b""")
IMPORT = re.compile(r"(import_playbook:\s*)(\S+)")
ASSET_SRC = re.compile(r"""(\bsrc:\s*)(?:"((?:files|templates)/[^"]*)"|'((?:files|templates)/[^']*)'|((?:files|templates)/\S*))""")


def read_map(path: pathlib.Path) -> dict[str, str]:
    moves: dict[str, str] = {}
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2 or not parts[0].endswith(".yml") or "/" in parts[0]:
            sys.exit(f"{path}:{n}: expected '<file>.yml <area>', got {raw!r}")
        name, area = parts
        if not AREA.fullmatch(area):
            sys.exit(f"{path}:{n}: area {area!r} must be one folder name")
        if not (PLAYBOOKS / name).is_file():
            sys.exit(f"{path}:{n}: ansible/playbooks/{name} does not exist")
        if name in moves:
            sys.exit(f"{path}:{n}: {name} is listed twice")
        moves[name] = area
    if not moves:
        sys.exit("the map holds no moves; refusing to report success over an empty set")
    return moves


def tracked_text_files() -> list[pathlib.Path]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True).stdout
    files = []
    for rel in out.decode().split("\0"):
        p = ROOT / rel
        if rel and rel not in SKIP and p.is_file() and not p.is_symlink() and p.suffix in TEXT_SUFFIXES:
            files.append(p)
    return files


def bare_asset(line: str) -> str:
    """A bare `src: x.j2` finds playbooks/templates/x.j2 only from the playbooks folder itself."""
    m = BARE_SRC.search(line)
    if m:
        for d in ("templates", "files"):
            if (PLAYBOOKS / d / m.group(2)).is_file():
                return line[: m.start()] + f'{m.group(1)}"{{{{ playbook_dir | dirname }}}}/{d}/{m.group(2)}"\n'
    m = FILE_LOOKUP.search(line)
    if m and (PLAYBOOKS / "files" / m.group(2)).is_file():
        return line[: m.start()] + f"{m.group(1)}playbook_dir ~ '/../files/{m.group(2)}'" + line[m.end():]
    return line


def main(argv: list[str]) -> int:
    apply = "--apply" in argv
    args = [a for a in argv[1:] if a != "--apply"]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    moves = read_map(pathlib.Path(args[0]))

    # Old path -> new path for every playbook that moves.
    old_to_new = {PLAYBOOKS / n: PLAYBOOKS / a / n for n, a in moves.items()}
    new_to_old = {v: k for k, v in old_to_new.items()}
    rel_new = {n: f"{a}/{n}" for n, a in moves.items()}
    names = "|".join(re.escape(n) for n in sorted(moves, key=len, reverse=True))
    path_ref = re.compile(rf"playbooks/({names})(?![\w-])")
    bare_ref = re.compile(rf"(?<![\w/.-])({names})(?![\w-])")

    files = tracked_text_files()
    changed: dict[pathlib.Path, str] = {}
    review: list[str] = []
    for f in files:
        # Where the file lives before the move, and after, since imports resolve from there.
        old_loc = f
        new_loc = old_to_new.get(f, f)
        moved = f in old_to_new
        try:
            lines = f.read_text().splitlines(keepends=True)
        except UnicodeDecodeError:
            continue
        out = []
        for line in lines:
            new = line
            m = IMPORT.search(new)
            if m:
                target = (old_loc.parent / m.group(2)).resolve()
                dest = old_to_new.get(target, target)
                if dest != target or moved:
                    rel = os.path.relpath(dest, new_loc.parent)
                    new = new[: m.start(2)] + rel + new[m.end(2):]
            else:
                new = path_ref.sub(lambda mm: f"playbooks/{rel_new[mm.group(1)]}", new)
                new = bare_ref.sub(lambda mm: rel_new[mm.group(1)], new)
            if moved:
                new = new.replace("{{ playbook_dir }}/../", "{{ playbook_dir }}/../../")
                new = new.replace("playbook_dir ~ '/../", "playbook_dir ~ '/../../")
                new = ASSET_SRC.sub(
                    lambda mm: f'{mm.group(1)}"{{{{ playbook_dir | dirname }}}}/{mm.group(2) or mm.group(3) or mm.group(4)}"', new)
            if moved:
                new = bare_asset(new)
                if TEMPLATED_SRC.search(new):
                    review.append(f"{f.relative_to(ROOT)}:{len(out) + 1}: {new.strip()}")
            out.append(new)
        text = "".join(out)
        if text != "".join(lines):
            changed[f] = text

    print(f"read {len(files)} tracked text files; {len(moves)} playbooks to move; "
          f"{len(changed)} files change")
    for n, a in sorted(moves.items(), key=lambda kv: (kv[1], kv[0])):
        print(f"  move {n} -> {a}/{n}")
    for line in review:
        print(f"  REVIEW by hand (loop-built src): {line}")
    if review and apply:
        print(f"{len(review)} loop-built src lines need a manual rewrite to "
              "{{ playbook_dir | dirname }}/templates/...; the script cannot see them.")
    if not apply:
        for f in sorted(changed):
            print(f"  rewrite {f.relative_to(ROOT)}")
        print("dry run: nothing written. Pass --apply to move the files and write the rewrites.")
        return 0

    for src, dst in old_to_new.items():
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "mv", str(src), str(dst)], cwd=ROOT, check=True)
    for f, text in changed.items():
        target = old_to_new.get(f, f)
        target.write_text(text)
    print(f"moved {len(old_to_new)} playbooks; rewrote {len(changed)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
