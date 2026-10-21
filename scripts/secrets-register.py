#!/usr/bin/env python3
"""secrets-register.py: check secrets/register.yml against the code and against Vault (PET-685).

The register lists every secret's owner, rotation method and expiry rule. It holds no values.
This script joins it with two other sources of truth:

  code   every `kv/...` path that scripts/, ansible/, environments/, modules/ and .github/
         name outside a comment, and outside vault-config (which holds grants, not reads)
  vault  (live mode) each path's KV metadata: `updated_time` and the current version

It fails (exit 1) when:
  - code reads a path that has no register entry, which means no owner
  - a register entry names a path that no code reads and that lists no `consumers_external`
  - an entry expires within WARN_DAYS, or has already expired
  - (live) an entry's path is absent from Vault and the entry is not `optional`

It exits 2, never 0, when the examination itself was incomplete: no register entries, too few
code files, or a Vault read that failed for any reason other than "absent". The last line says
what was examined, so "0 problems" cannot hide "0 examined".

Usage:
  scripts/secrets-register.py                 offline: register against code
  scripts/secrets-register.py --live          also read Vault KV metadata (nightly job)
  scripts/secrets-register.py --report [FILE] write the generated register as Markdown (stdout by default)
  scripts/secrets-register.py --self-test     prove an entry that expires in 7 days fails

`--report` joins the register with the Vault policies in vault-config (which role can read each
path), the code that reads it, and, in live mode, the last write time. It runs the same checks
first and exits non-zero when they fail, so a report never hides a failing register.

Live mode reads $VAULT_ADDR and $VAULT_TOKEN, and trusts $VAULT_CACERT when it is set. It
reads metadata only, never a secret value.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

try:
    import yaml
except ImportError:  # fail closed: a checker that cannot read its register checks nothing
    print("secrets-register: PyYAML is not installed, so nothing was examined.", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REGISTER = os.environ.get("SECRETS_REGISTER") or os.path.join(REPO_ROOT, "secrets", "register.yml")
SCAN_DIRS = ["scripts", "ansible", "environments", "modules", ".github"]
# vault-config holds policy grants and auth roles. A grant names a path, but it reads nothing.
SKIP_PREFIXES = ("environments/homelab/vault-config/",)
SKIP_FILES = {"scripts/secrets-register.py"}
SKIP_SUFFIXES = (".lock", ".png", ".crt", ".pem", ".md")
WARN_DAYS = 21
MIN_FILES = 40
MIN_ENTRIES = 10

# A reference runs to the first character a Vault path cannot hold. Template characters end it,
# and mark the reference as dynamic: only its prefix is known.
REF = re.compile(r"kv/(?:data/|metadata/)?([A-Za-z0-9_-]+(?:/[A-Za-z0-9_.*<$-]+)*)")
DYNAMIC = re.compile(r"[*<$]")


def is_comment(line: str) -> bool:
    s = line.lstrip()
    return s.startswith("#") or s.startswith("//")


def scan_code() -> tuple[dict[str, set[str]], int]:
    """Return {reference: {files}} and the number of files read."""
    refs: dict[str, set[str]] = {}
    nfiles = 0
    for top in SCAN_DIRS:
        base = os.path.join(REPO_ROOT, top)
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in (".terraform", "node_modules", ".git")]
            for name in files:
                rel = os.path.relpath(os.path.join(root, name), REPO_ROOT)
                if rel.startswith(SKIP_PREFIXES) or rel in SKIP_FILES or rel.endswith(SKIP_SUFFIXES):
                    continue
                try:
                    with open(os.path.join(root, name), encoding="utf-8") as fh:
                        lines = fh.read().splitlines()
                except (UnicodeDecodeError, OSError):
                    continue
                nfiles += 1
                for line in lines:
                    if is_comment(line):
                        continue
                    for m in REF.finditer(line):
                        ref = "kv/" + m.group(1).rstrip(".")
                        # A mount or a bare directory ("kv/services/") names no secret.
                        if ref.count("/") < 2 or ref.endswith("/"):
                            continue
                        refs.setdefault(ref, set()).add(rel)
    return refs, nfiles


def covers(entry_path: str, ref: str) -> bool:
    """True when an entry's path (a glob, or a path with a field suffix) accounts for ref."""
    m = DYNAMIC.search(ref)
    if m:
        prefix = ref[: m.start()]
        return entry_path.startswith(prefix) or fnmatch.fnmatch(prefix, entry_path.rstrip("/") + "*")
    # Nested KV paths are distinct secrets, not fields of their parent, so match exactly.
    return fnmatch.fnmatch(ref, entry_path)


POLICY_BLOCK = re.compile(r'resource\s+"vault_policy"\s+"[^"]+"\s*\{(.*?)\n\}', re.S)
POLICY_NAME = re.compile(r'name\s*=\s*"([^"]+)"')
POLICY_PATH = re.compile(r'path\s+"kv/data/([^"]+)"\s*\{[^}]*?capabilities\s*=\s*\[([^\]]*)\]', re.S)


def scan_policies() -> tuple[list[tuple[str, str, str]], int]:
    """Return [(policy, glob, capabilities)] for each kv/data grant in vault-config, and the policy count."""
    grants: list[tuple[str, str, str]] = []
    npol = 0
    path = os.path.join(REPO_ROOT, "environments", "homelab", "vault-config", "policies.tf")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for block in POLICY_BLOCK.findall(text):
        name = POLICY_NAME.search(block)
        if not name:
            continue
        npol += 1
        for glob, caps in POLICY_PATH.findall(block):
            caps = ",".join(c.strip().strip('"') for c in caps.split(",") if c.strip())
            grants.append((name.group(1), "kv/" + glob, caps))
    return grants, npol


def load_register(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict) or not isinstance(doc.get("secrets"), list):
        raise SystemExit("secrets-register: register.yml has no `secrets:` list.")
    return doc["secrets"]


def expiry_error(entry: dict) -> str | None:
    """Return why an `expiry` declaration is malformed, or None when it is valid."""
    rule = entry.get("expiry")
    if not isinstance(rule, dict) or "rule" not in rule:
        return "`expiry` must be a mapping with a `rule` (none, date or ttl_days)"
    kind = rule["rule"]
    if kind == "none":
        return None
    if kind == "date":
        d = rule.get("date")
        if isinstance(d, dt.datetime) or not isinstance(d, dt.date):
            return "`expiry.date` must be an unquoted YYYY-MM-DD date"
        return None
    if kind == "ttl_days":
        days = rule.get("days")
        if isinstance(days, bool) or not isinstance(days, int) or days <= 0:
            return "`expiry.days` must be a positive integer"
        return None
    return f"unknown expiry rule {kind!r}"


def expiry_of(entry: dict, updated: dt.datetime | None) -> tuple[dt.date | None, str]:
    rule = entry.get("expiry") or {}
    kind = rule.get("rule")
    if kind in (None, "none"):
        return None, "no expiry"
    if kind == "date":
        d = rule.get("date")
        if isinstance(d, dt.datetime):
            d = d.date()
        if not isinstance(d, dt.date):
            return None, "bad date"
        return d, f"fixed date {d}"
    if kind == "ttl_days":
        days = int(rule.get("days", 0))
        if updated is None:
            return None, "ttl_days needs live mode"
        return (updated + dt.timedelta(days=days)).date(), f"{days} days after {updated.date()}"
    return None, f"unknown rule {kind!r}"


def check(entries: list[dict], refs: dict[str, set[str]], today: dt.date,
          metadata: dict[str, dict | None] | None) -> list[str]:
    problems: list[str] = []
    seen: set[str] = set()
    for e in entries:
        for field in ("path", "owner", "rotation", "expiry"):
            if field not in e:
                problems.append(f"entry {e.get('path', e)!r} has no `{field}`")
        for field in ("path", "owner", "rotation"):
            v = e.get(field)
            if field in e and not (isinstance(v, str) and v.strip()):
                problems.append(f"entry {e.get('path', e)!r}: `{field}` must be a non-empty string")
        p = e.get("path", "")
        if p in seen:
            problems.append(f"{p}: listed twice")
        seen.add(p)
        if "*" in p and e.get("kind") != "external":
            problems.append(f"{p}: a wildcard path checks no concrete secret, so list each path")
        bad = expiry_error(e) if "expiry" in e else None
        if bad:
            problems.append(f"{p}: {bad}")
        for f in e.get("fields") or []:
            fname = f.get("name") if isinstance(f, dict) else None
            if not (isinstance(fname, str) and fname.strip()
                    and isinstance(f.get("rotation"), str) and f["rotation"].strip()
                    and not expiry_error(f)):
                problems.append(f"{p}: each `fields` item needs a `name`, a `rotation` and a valid `expiry`")

    # Code that reads a path no entry accounts for.
    for ref, files in sorted(refs.items()):
        if not any(covers(e.get("path", "\0"), ref) for e in entries):
            problems.append(f"{ref}: read by {sorted(files)[0]}"
                            f"{' and %d more' % (len(files) - 1) if len(files) > 1 else ''}, but has no owner in the register")

    for e in entries:
        p = e.get("path", "")
        if e.get("kind") == "external" or e.get("status") == "retired":
            consumed = True
        else:
            consumed = any(covers(p, r) for r in refs) or bool(e.get("consumers_external"))
        if not consumed:
            problems.append(f"{p}: no code reads it and the entry names no `consumers_external`")

        updated = None
        meta = (metadata or {}).get(p)
        if metadata is not None and e.get("kind") != "external" and e.get("status") != "retired":
            if meta is None:
                if not e.get("optional"):
                    problems.append(f"{p}: absent from Vault (mark it `optional: true` if it is not seeded yet)")
            else:
                updated = meta["updated"]
        when, why = expiry_of(e, updated)
        if when is not None:
            left = (when - today).days
            if left < 0:
                problems.append(f"{p}: expired {-left} days ago ({why})")
            elif left < WARN_DAYS:
                problems.append(f"{p}: expires in {left} days ({why})")
    return problems


def vault_metadata(entries: list[dict]) -> tuple[dict[str, dict | None], int]:
    addr = os.environ.get("VAULT_ADDR", "").rstrip("/")
    token = os.environ.get("VAULT_TOKEN", "")
    if not addr or not token:
        print("secrets-register: --live needs VAULT_ADDR and VAULT_TOKEN, so nothing was read.", file=sys.stderr)
        sys.exit(2)
    ctx = ssl.create_default_context(cafile=os.environ.get("VAULT_CACERT") or None)
    out: dict[str, dict | None] = {}
    reads = 0
    for e in entries:
        p = e.get("path", "")
        if e.get("kind") == "external" or e.get("status") == "retired" or not p.startswith("kv/"):
            continue
        req = urllib.request.Request(f"{addr}/v1/kv/metadata/{p[len('kv/'):]}",
                                     headers={"X-Vault-Token": token})
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                data = json.load(resp)["data"]
            reads += 1
            m = re.match(r"(.*?)(\.\d+)?Z$", data["updated_time"])
            if not m:
                raise ValueError(f"unparseable updated_time {data['updated_time']!r}")
            # Vault prints nanoseconds; datetime reads six digits.
            ts = m.group(1) + (m.group(2) or "")[:7] + "+00:00"
            out[p] = {"updated": dt.datetime.fromisoformat(ts), "version": data["current_version"]}
        except urllib.error.HTTPError as err:
            if err.code == 404:
                reads += 1
                out[p] = None
            else:
                print(f"secrets-register: Vault answered {err.code} for {p}, so the read is incomplete.",
                      file=sys.stderr)
                sys.exit(2)
        except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as err:
            print(f"secrets-register: could not read {p}: {err}", file=sys.stderr)
            sys.exit(2)
    return out, reads


def consumers_of(path: str, refs: dict[str, set[str]]) -> list[str]:
    return sorted({f for r, files in refs.items() if covers(path, r) for f in files})


def render_report(entries: list[dict], refs: dict[str, set[str]], grants: list[tuple[str, str, str]],
                  metadata: dict[str, dict | None] | None, today: dt.date) -> str:
    """Render the register as Markdown. It carries paths, owners and dates, never a value."""
    def cell(v: str) -> str:
        return v.replace("|", "\\|").replace("\n", " ")

    live = metadata is not None
    out = [
        "# Generated secrets register",
        "",
        f"Generated {today} by `scripts/secrets-register.py --report` from `secrets/register.yml`, the",
        "`kv/...` references in the code and the Vault policies in `vault-config/policies.tf`. "
        + ("Last write times come from Vault KV metadata." if live
           else "Offline: last write times need `--live`, so they read `unknown`."),
        "It holds no secret values.",
        "",
        "| Vault path | Owner | Read by (Vault roles) | Consumers (code) | Rotation | Last write | Expiry |",
        "|---|---|---|---|---|---|---|",
    ]
    for e in entries:
        p = e.get("path", "")
        roles = sorted({f"{pol} ({caps})" for pol, glob, caps in grants if fnmatch.fnmatch(p, glob)})
        cons = consumers_of(p, refs)
        ext = e.get("consumers_external")
        consumer = ", ".join(f"`{c}`" for c in cons[:4]) + (f" +{len(cons) - 4} more" if len(cons) > 4 else "")
        if ext:
            consumer = (consumer + "; " if consumer else "") + str(ext)
        meta = (metadata or {}).get(p)
        if meta is not None:
            last = str(meta["updated"].date())
        elif e.get("rotated"):
            last = str(e["rotated"])
        else:
            last = "unknown" if not live else ("absent" if e.get("kind") != "external" else "unknown")
        when, why = expiry_of(e, meta["updated"] if meta else None)
        expiry = str(when) if when else "none"
        out.append("| " + " | ".join(cell(x) for x in (
            f"`{p}`", e.get("owner", ""), "; ".join(roles) or "none", consumer or "none",
            e.get("rotation", ""), last, expiry)) + " |")
        for f in e.get("fields") or []:
            fw, _ = expiry_of(f, None)
            out.append("| " + " | ".join(cell(x) for x in (
                f"&nbsp;&nbsp;↳ field `{f.get('name', '')}`", f.get("owner", e.get("owner", "")),
                "", f.get("consumer", ""), f.get("rotation", ""), "",
                str(fw) if fw else "none")) + " |")
    out += ["", f"{len(entries)} entries, {len(grants)} policy grants read."]
    return "\n".join(out) + "\n"


def self_test() -> int:
    """An entry that expires in 7 days must fail, and one that expires in 60 must not."""
    today = dt.date(2026, 1, 1)
    refs = {"kv/services/probe": {"scripts/x.sh"}}
    base = {"path": "kv/services/probe", "owner": "pedro", "rotation": "manual"}
    soon = dict(base, expiry={"rule": "date", "date": today + dt.timedelta(days=7)})
    later = dict(base, expiry={"rule": "date", "date": today + dt.timedelta(days=60)})
    bad = check([soon], refs, today, None)
    good = check([later], refs, today, None)
    orphan = check([later], {**refs, "kv/services/other": {"scripts/y.sh"}}, today, None)
    # A quoted date, an unknown rule and an empty mapping must fail, not pass as "no expiry".
    quoted = check([dict(base, expiry={"rule": "date", "date": "2027-01-01"})], refs, today, None)
    unknown = check([dict(base, expiry={"rule": "weekly"})], refs, today, None)
    empty = check([dict(base, expiry={})], refs, today, None)
    # A retired entry whose path is gone from Vault is correct; a live one is not.
    gone = {"kv/services/probe": None}
    retired = check([dict(later, status="retired")], refs, today, gone)
    live_gone = check([later], refs, today, gone)
    blank = check([dict(later, owner=None, rotation="  ")], refs, today, None)
    child = check([later], {**refs, "kv/services/probe/child": {"scripts/z.sh"}}, today, None)
    wild = check([dict(later, path="kv/services/probe-*")], refs, today, None)
    badfield = check([dict(later, fields=[{"name": "k"}])], refs, today, None)
    report = render_report([dict(later, fields=[{"name": "k", "rotation": "manual", "expiry": {"rule": "none"}}])],
                           refs, [("pol", "kv/services/probe", "read")], None, today)
    ok = (bool(bad) and bool(badfield) and "pol (read)" in report and "field `k`" in report and not good and any("no owner" in p for p in orphan)
          and quoted and unknown and empty and not retired and live_gone
          and any("wildcard" in p for p in wild)
          and len(blank) >= 2 and any("no owner" in p for p in child))
    print(f"self-test: quoted date / unknown rule / empty expiry -> {bool(quoted and unknown and empty)}")
    print(f"self-test: retired 404 passes -> {not retired}; live 404 fails -> {bool(live_gone)}")
    print(f"self-test: 7-day entry -> {bad or 'NO PROBLEM (wrong)'}")
    print(f"self-test: 60-day entry -> {good or 'no problems'}")
    print(f"self-test: unowned path -> {orphan or 'NO PROBLEM (wrong)'}")
    print("self-test: " + ("passed" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--live", action="store_true", help="also read Vault KV metadata")
    ap.add_argument("--report", nargs="?", const="-", metavar="FILE",
                    help="write the generated register as Markdown (- for stdout)")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--today", help="override today's date (YYYY-MM-DD), for tests")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    entries = load_register(REGISTER)
    refs, nfiles = scan_code()
    metadata, reads = (vault_metadata(entries) if args.live else (None, 0))

    problems = check(entries, refs, today, metadata)
    for p in problems:
        print(f"FAIL {p}", file=sys.stderr if args.report == "-" else sys.stdout)
    grants, npol = scan_policies()
    if args.report:
        if npol < 5:
            print(f"secrets-register: read only {npol} Vault policies, so the report is incomplete.",
                  file=sys.stderr)
            return 2
        text = render_report(entries, refs, grants, metadata, today)
        if args.report == "-":
            sys.stdout.write(text)
        else:
            with open(args.report, "w", encoding="utf-8") as fh:
                fh.write(text)
    absent = sum(1 for v in (metadata or {}).values() if v is None)
    summary = (f"examined {len(entries)} register entries, {len(refs)} distinct kv references "
               f"in {nfiles} files; vault: " +
               (f"{reads} metadata reads, {absent} absent" if args.live else "not read (offline)") +
               f"; {len(problems)} problems")
    summary += f"; {npol} policies, {len(grants)} grants" if args.report else ""
    print(summary, file=sys.stderr if args.report == "-" else sys.stdout)
    if len(entries) < MIN_ENTRIES or nfiles < MIN_FILES:
        print(f"secrets-register: below the floor ({MIN_ENTRIES} entries, {MIN_FILES} files), "
              "so this run examined too little to pass.", file=sys.stderr)
        return 2
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
