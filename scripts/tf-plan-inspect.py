#!/usr/bin/env python3
"""Parse a pull request's Terraform and refuse what could send credentials elsewhere (PET-866).

This is the second guard. tf-plan-guard.py reads text; this script parses it with python-hcl2 and
compares the merged tree with main's. It runs in a credential-free hosted job, so the pull
request's HCL never reaches a runner that holds credentials unless both guards pass.

The rule is that the PR may not change what the credentialed plan can reach:
  * provider blocks, terraform blocks (required_providers, backend, cloud): equal to main's
  * provisioner blocks, `provider` and `providers` arguments: same count as main
  * Vault resources, data sources and ephemeral blocks: equal to main's
  * file-reading functions and nonsensitive(): same count as main
  * module sources: one of three reviewed paths, exactly
  * resource, data and ephemeral types: from a provider in main's lock file (plus terraform_data)
  * a file python-hcl2 cannot parse: refused, whatever Terraform would make of it

Residual risk: python-hcl2 is not Terraform's parser. A file it parses differently from
Terraform is the gap. The provider mirror, the text guard and the redacted comment cover it in
depth. docs/GOTCHAS.md records this.

Usage: tf-plan-inspect.py --base DIR --head DIR [--lock FILE]
DIR is a checkout root. Exit 0 safe, 1 refused, 2 could not run. Always prints what it examined.
"""
import glob
import json
import os
import re
import sys

ROOTS = ["environments/homelab", "modules/proxmox-lxc", "modules/postgres-db",
         "modules/cloudflare-ingress", "modules/baremetal-host"]
# The text guard allows the first three only, so an edit to a file that calls baremetal-host
# (ollama.tf) is refused there. This list lets main's own unchanged calls pass this guard.
ALLOWED_SOURCES = {"../../modules/proxmox-lxc", "../../modules/postgres-db",
                   "../../modules/cloudflare-ingress", "../../modules/baremetal-host"}
KNOWN_TOP = {"resource", "data", "ephemeral", "module", "variable", "locals", "output", "moved",
             "import", "removed", "check", "terraform", "provider", "__comments__"}
FUNCS = re.compile(r'\b(file\w*|templatefile|pathexpand|nonsensitive|sensitive)\s*\(')


def unq(s):
    return s[1:-1] if isinstance(s, str) and len(s) >= 2 and s[0] == s[-1] == '"' else s


def load_dir(base, root):
    import hcl2
    docs = []
    d = os.path.join(base, root)
    for f in sorted(glob.glob(os.path.join(d, "*.tf"))):
        with open(f, encoding="utf-8", errors="strict") as fh:
            docs.append((os.path.relpath(f, base), hcl2.load(fh)))
    return docs


def walk(node, fn, key=None):
    fn(node, key)
    if isinstance(node, dict):
        for k, v in node.items():
            walk(v, fn, unq(k))
    elif isinstance(node, list):
        for v in node:
            walk(v, fn, key)


def canon(x):
    return json.dumps(x, sort_keys=True)


def facts(base):
    f = {"provider": [], "terraform": [], "vault": [], "provisioner": 0, "meta": 0,
         "funcs": 0, "types": set(), "sources": [], "unknown": [], "files": 0, "check": 0}
    for root in ROOTS:
        for rel, doc in load_dir(base, root):
            f["files"] += 1
            for top, blocks in doc.items():
                if top == "check":
                    # A check block can hold a scoped data source, so any change is refused.
                    f["check"] += len(blocks)
                if top not in KNOWN_TOP:
                    f["unknown"].append(f"{rel}:{top}")
                if top in ("provider", "terraform"):
                    f[top].append(canon([rel, blocks]))
                if top in ("resource", "data", "ephemeral"):
                    for b in blocks:
                        for typ, named in b.items():
                            t = unq(typ)
                            f["types"].add(t)
                            if t.startswith("vault_"):
                                f["vault"].append(canon([rel, top, t, named]))
                if top == "module":
                    for b in blocks:
                        for name, body in b.items():
                            f["sources"].append((rel, unq(name), unq(body.get("source", ""))))

            def visit(n, key):
                if key == "provisioner":
                    f["provisioner"] += 1
                if key in ("provider", "providers") and isinstance(n, (str, list, dict)):
                    f["meta"] += 1
                if isinstance(n, str):
                    f["funcs"] += len(FUNCS.findall(n))
            body_only = {k: v for k, v in doc.items() if k not in ("provider", "terraform", "__comments__")}
            walk(body_only, visit)
    for k in ("provider", "terraform", "vault"):
        f[k].sort()
    return f


def prefixes(lock):
    names = re.findall(r'provider\s+"registry\.terraform\.io/[^/"]+/([^"]+)"', open(lock).read())
    if not names:
        raise RuntimeError(f"no providers found in {lock}")
    return tuple(n + "_" for n in names) + ("terraform_data",)


def main():
    a = sys.argv[1:]
    try:
        base, head = a[a.index("--base") + 1], a[a.index("--head") + 1]
        lock = a[a.index("--lock") + 1] if "--lock" in a else os.path.join(base, "environments/homelab/.terraform.lock.hcl")
    except (ValueError, IndexError):
        print(__doc__)
        return 2
    try:
        import hcl2  # noqa: F401
    except ImportError:
        print("inspect error: python-hcl2 is not installed")
        return 2
    try:
        fb = facts(base)
    except Exception as e:  # main's own tree must parse, or the comparison means nothing
        print(f"inspect error: main does not parse: {type(e).__name__}")
        return 2
    reasons = []
    try:
        fh = facts(head)
    except Exception as e:
        print("REFUSE a Terraform file could not be parsed: " + type(e).__name__)
        return 1
    if fh["files"] == 0:
        print("inspect error: parsed 0 files")
        return 2
    pre = prefixes(lock)
    for k in ("provider", "terraform", "vault"):
        if fh[k] != fb[k]:
            reasons.append(f"{k} blocks differ from main's")
    for k, why in (("check", "check blocks"), ("provisioner", "provisioner blocks"), ("meta", "provider or providers arguments"),
                   ("funcs", "file-reading functions or nonsensitive()")):
        if fh[k] != fb[k]:
            reasons.append(f"count of {why} differs from main's ({fb[k]} to {fh[k]})")
    for rel, name, src in fh["sources"]:
        if src not in ALLOWED_SOURCES:
            reasons.append(f"module {name} in {rel} has a source outside the reviewed set")
    for t in sorted(fh["types"]):
        if not t.startswith(pre):
            reasons.append(f"resource type {t} is not from a provider in main's lock")
    for u in fh["unknown"]:
        reasons.append(f"unknown top-level block {u}")
    n_files = fh["files"]
    print(f"inspect parsed {n_files} files in {len(ROOTS)} roots; "
          f"{len(fh['types'])} resource types, {len(fh['sources'])} module calls")
    if n_files == 0:
        print("inspect error: parsed 0 files")
        return 2
    for r in sorted(set(reasons)):
        print("REFUSE " + ascii(r)[1:-1].replace("`", "?"))
    return 1 if reasons else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:
        print(f"inspect error: {type(e).__name__}: {e}")
        sys.exit(2)
