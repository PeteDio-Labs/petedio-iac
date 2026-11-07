#!/usr/bin/env python3
"""Print the allowlisted repository variables the workflow passes in (PET-884).

Reads $REPO_VARS_JSON, the workflow's `toJSON(vars)`, and the allowlist file given as argv[1].
It prints each allowlisted name as set (with its value) or unset, and ends with a summary that
says how many names it examined. It exits 1 when the input is missing or not a JSON object, so a
workflow that passed nothing never reads as "every variable is unset".

Repository variables are not secrets, but the run log is public: only allowlisted names print.
"""
import json
import os
import re
import sys

NAME = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
VALUE_CAP = 80


def load_allowlist(path):
    names = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if not NAME.match(line):
            raise ValueError(f"bad name in allowlist: {line!r}")
        names.append(line)
    if not names:
        raise ValueError("the allowlist is empty")
    return names


def main(argv):
    if len(argv) != 2:
        print("usage: lab-repo-vars.py <allowlist>", file=sys.stderr)
        return 2
    raw = os.environ.get("REPO_VARS_JSON", "")
    try:
        names = load_allowlist(argv[1])
        held = json.loads(raw)
        if not isinstance(held, dict):
            raise ValueError("REPO_VARS_JSON is not a JSON object")
    except (OSError, ValueError) as err:
        print(f"FAILED: {err}; no variable was examined.", file=sys.stderr)
        return 1
    is_set = 0
    for name in names:
        if name in held:
            is_set += 1
            value = str(held[name]).replace("\n", " ")[:VALUE_CAP]
            print(f"{name} = {value}")
        else:
            print(f"{name} is unset")
    print(f"probe repo_vars: examined {len(names)} allowlisted names of {len(held)} variables held, {is_set} set")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
