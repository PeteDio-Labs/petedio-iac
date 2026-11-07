#!/usr/bin/env python3
"""vault-config-drift: compare the policy and role names Vault holds with the names vault-config declares (PET-894).

    scripts/vault-config-drift.py <live.json> [vault-config-dir]

<live.json> is written by scripts/lab-action.sh before it revokes its Vault token:

    {"policies": [...] | null, "jwt_roles": [...] | null, "approle_roles": [...] | null}

A null list means Vault refused or failed that listing, so the check reports it as unread.

It compares NAMES only, never bodies: a policy edited by hand under its declared name is not found
here. The declared names come from the .tf files. A name that holds `${...}` (a for_each key) becomes a
pattern, so `deploy-${each.key}` matches any `deploy-<host>`. Vault's built-in `default` and `root`
policies are ignored. The log is public, so it prints names, counts and nothing else.

Prints one line per kind and a last line `probe vault_drift: ...` that says what was examined.
Exit 0 = no drift, 1 = drift or a partly unreadable listing, 2 = bad input, 3 = Vault refused every
listing (the lab-action-read policy lacks the list grant), so nothing was compared.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

BUILTIN = {"default", "root"}
KINDS = (
    ("policies", "vault_policy", "name"),
    ("jwt_roles", "vault_jwt_auth_backend_role", "role_name"),
    ("approle_roles", "vault_approle_auth_backend_role", "role_name"),
)


def declared(tf_dir: pathlib.Path, rtype: str, key: str) -> tuple[set[str], list[re.Pattern[str]], int]:
    """Return (static names, patterns for templated names, .tf files read)."""
    static: set[str] = set()
    patterns: list[re.Pattern[str]] = []
    files = sorted(tf_dir.glob("*.tf"))
    head = re.compile(r'^resource\s+"%s"\s+"[^"]+"\s*\{' % re.escape(rtype), re.M)
    attr = re.compile(r'^\s*%s\s*=\s*"([^"\n]+)"' % re.escape(key), re.M)
    for f in files:
        text = f.read_text()
        for m in head.finditer(text):
            # The resource body runs to the next top-level `resource`, `data`, `locals` or `output` header.
            nxt = re.search(r'^(resource|data|locals|output|variable|module)\b', text[m.end():], re.M)
            body = text[m.end(): m.end() + nxt.start()] if nxt else text[m.end():]
            a = attr.search(body)
            if not a:
                continue
            name = a.group(1)
            if "${" in name:
                parts = re.split(r"\$\{[^}]*\}", name)
                patterns.append(re.compile("^" + "[A-Za-z0-9._-]+".join(re.escape(p) for p in parts) + "$"))
            else:
                static.add(name)
    return static, patterns, len(files)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    tf_dir = pathlib.Path(argv[2]) if len(argv) > 2 else pathlib.Path(__file__).resolve().parent.parent / "environments/homelab/vault-config"
    try:
        live = json.loads(pathlib.Path(argv[1]).read_text())
        assert isinstance(live, dict)
    except Exception as e:  # noqa: BLE001 - any unreadable input is a refusal
        print(f"FAILED: cannot read the live listing: {e}", file=sys.stderr)
        return 2
    unread = 0
    bad = 0
    total_live = total_decl = 0
    for k, rtype, attrname in KINDS:
        names = live.get(k)
        static, patterns, nfiles = declared(tf_dir, rtype, attrname)
        if nfiles == 0 or not (static or patterns):
            print(f"FAILED: no {rtype} declarations found in {tf_dir}, so nothing to compare", file=sys.stderr)
            return 2
        if names is None:
            print(f"{k}: unread (Vault refused or failed the listing)")
            bad += 1
            unread += 1
            continue
        if not isinstance(names, list):
            print(f"FAILED: live {k} is not a list", file=sys.stderr)
            return 2
        got = {n for n in names if k != "policies" or n not in BUILTIN}
        undeclared = sorted(n for n in got if n not in static and not any(p.match(n) for p in patterns))
        missing = sorted(static - got)
        total_live += len(got)
        total_decl += len(static) + len(patterns)
        status = "ok" if not undeclared and not missing else "DRIFT"
        line = f"{k}: {status} live={len(got)} declared={len(static)}+{len(patterns)} patterns"
        if undeclared:
            line += " in-vault-not-declared=" + ",".join(undeclared)[:300]
        if missing:
            line += " declared-not-in-vault=" + ",".join(missing)[:300]
        print(line)
        bad += bool(undeclared or missing)
    if unread == len(KINDS):
        print("probe vault_drift: compared 0 names; Vault refused all 3 listings")
        return 3
    print(f"probe vault_drift: compared {total_live} live names with {total_decl} declarations (names only, not bodies); {bad} kind(s) differ or unread")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
