#!/usr/bin/env python3
"""Decide whether a pull request's Terraform may be planned on the homelab runner (PET-866).

A plan runs the pull request's own Terraform with the runner's credentials, and this repo is
public. This guard is an allowlist of what a PR may change. It is the second layer: the workflow
first installs providers only from a mirror built from main's lock file, so a PR cannot add a
provider (`external`, `archive`, `http`, `local`) at all, whatever its HCL says. The guard covers
what a provider mirror does not: built-in execution (`provisioner`), file reads, remote-state
reads, symlinks, and changes to the files that say where credentials go.

It matches raw text, never stripped text, so a comment cannot hide a token. A false refusal costs
a local plan. A false pass costs a credential.

Usage: tf-plan-guard.py <checkout> [--base REV] [--head REV]

Defaults compare HEAD^1 (main) with HEAD, the merge ref. Exit 0 means safe to plan, 1 means
refuse, 2 means the guard could not read the diff. Exit 2 is a failure, never a pass. The guard
prints what it examined on every path.
"""
import re
import subprocess
import sys

# Gap between two tokens. HCL treats whitespace, /* */, // and # comments alike here.
W = r'(?:\s|/\*.*?\*/|(?://|#)[^\n]*(?:\n|\Z))*'

# Whole-file tokens, checked in every changed Terraform file.
FILE_TOKENS = [
    (r'\bprovisioner\b|\blocal-exec\b|\bremote-exec\b', "provisioner"),
    # Whitespace and /* */ comments may sit between tokens in HCL. The provider mirror in the
    # workflow is the real block on these providers; this is the second layer.
    (r'\bdata\b' + W + r'"?(external|http|archive_file|dns_\w+|local_\w+|tls_\w+)\b',
     "data source of an execution or network provider"),
    (r'\bterraform_remote_state\b', "remote state read"),
    (r'\bprovider' + W + r'"|\brequired_providers\b', "provider configuration"),
    (r'\bproviders?' + W + r'=', "provider meta-argument"),
    (r'\bbackend' + W + r'"', "backend block"),
    (r'\\[uU][0-9a-fA-F]{4}', "unicode escape in a string"),
    # A function call may have comments between the name and "(" in HCL.
    (r'\b(file|fileexists|fileset|filebase64|filebase64sha256|filebase64sha512|filemd5|filesha1|filesha256|filesha512|templatefile|pathexpand|nonsensitive)\b'
     + W + r'\(', "file read or nonsensitive()"),
]
# Checked on a file's added lines only: Vault reads already in the file stay legal, and a
# Vault read added by the diff is refused.
ADDED_TOKENS = [
    (r'\b(data|ephemeral|resource)\b' + W + r'"?vault_', "new Vault read or write"),
]
# Every `source =` in a changed file must name one reviewed module. It is not anchored to a line
# start, so `module "x" { source = "git::..." }` on one line is still caught.
SOURCE = re.compile(r'\bsource' + W + r'=' + W + r'("([^"]*)")?', re.S)
ALLOWED_SOURCE = re.compile(r'^\.\./\.\./modules/(proxmox-lxc|postgres-db|cloudflare-ingress)$')
SAFE_NAME = re.compile(r'^[A-Za-z0-9._/@+=,-]+$')

FORBIDDEN_PATH = [
    (r'(^|/)\.terraform\.lock\.hcl$', "provider lock file"),
    (r'(^|/)(override|.*_override)\.tf(\.json)?$', "override file"),
    (r'\.tf\.json$', "JSON configuration"),
    (r'(^|/)\.terraformrc$|\.tfrc$', "CLI config file"),
    (r'(^|/)backend\.tf$', "backend configuration"),
    (r'^environments/homelab/(providers|variables|versions)\.tf$', "defines a provider destination"),
    (r'\.tfvars(\.json)?$|\.auto\.tfvars', "variable values file"),
    (r'(^|/)\.terraform(/|$)|\.tfstate', "Terraform working directory or state"),
    (r'^modules/baremetal-host/', "module that holds a local-exec provisioner"),
]
ALLOWED_ROOTS = re.compile(
    r'^(environments/homelab/[^/]+$|modules/(proxmox-lxc|postgres-db|cloudflare-ingress)/)')
PLANNED = re.compile(
    r'^(environments/homelab/(?!vault-config/)|modules/(proxmox-lxc|postgres-db|cloudflare-ingress|baremetal-host)(/|$))')
TERRAFORM_FILE = re.compile(r'\.(tf|tfvars|hcl)$|\.tf\.json$')


def safe(p):
    """A path is attacker text. Escape it so it cannot forge a line the workflow parses."""
    return ascii(p)[1:-1].replace("`", "?")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True)


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        return 2
    repo, base, head = argv[0], "HEAD^1", "HEAD"
    for i, a in enumerate(argv):
        if a == "--base":
            base = argv[i + 1]
        if a == "--head":
            head = argv[i + 1]
    # -z: git quotes unusual file names otherwise, and a quoted name matches no path rule.
    raw = git(repo, "diff", "--raw", "-z", "--no-renames", f"{base}..{head}")
    if raw.returncode != 0:
        print(f"guard error: git diff failed: {raw.stderr.decode(errors='replace').strip()}")
        return 2
    parts = raw.stdout.decode(errors="surrogateescape").split("\0")
    entries = []  # (new mode, status, path)
    i = 0
    while i + 1 < len(parts) and parts[i].startswith(":"):
        meta = parts[i].split()
        entries.append((meta[1], meta[4], parts[i + 1]))
        i += 2
    if not entries:
        print(f"guard error: {base}..{head} changed 0 files, so nothing was examined")
        return 2
    files = [p for _, _, p in entries]
    unsafe = [p for p in files
              if (PLANNED.match(p) or TERRAFORM_FILE.search(p)) and not SAFE_NAME.fullmatch(p)]
    if unsafe:
        # A name is attacker text. Print it escaped and never as a bare line, so it cannot forge
        # the PLANNED_PATHS or REFUSE lines the workflow parses.
        print(f"guard examined {len(files)} changed files, 0 under planned paths")
        print("PLANNED_PATHS=0")
        for p in unsafe:
            print("REFUSE file name with characters outside the safe set: " + safe(p))
        return 1
    planned = [p for p in files if PLANNED.match(p)]
    reasons = []
    for mode, status, p in entries:
        # Anywhere in the repo: a symlink can stand in for a parent directory of a planned path.
        if mode in ("120000", "160000") and status != "D":
            reasons.append(f"{safe(p)}: symlink or submodule")
        if not PLANNED.match(p):
            continue  # Only paths the homelab root can load matter. vault-config has its own state.
        for pat, why in FORBIDDEN_PATH:
            if re.search(pat, p):
                reasons.append(f"{safe(p)}: {why}")
        if status == "D" or not TERRAFORM_FILE.search(p):
            continue
        body = git(repo, "show", f"{head}:{p}")
        if body.returncode != 0:
            print(f"guard error: cannot read {p} at {head}")
            return 2
        text = body.stdout.decode(errors="replace")
        for pat, why in FILE_TOKENS:
            if re.search(pat, text, re.S):
                reasons.append(f"{safe(p)}: {why}")
        for m in SOURCE.finditer(text):
            if m.group(2) is None or not ALLOWED_SOURCE.match(m.group(2)):
                reasons.append(f"{safe(p)}: source other than the three reviewed modules")
        d = git(repo, "diff", "-U0", f"{base}..{head}", "--", p)
        added = "\n".join(l[1:] for l in d.stdout.decode(errors="replace").splitlines()
                          if l.startswith("+") and not l.startswith("+++"))
        # A Vault block already in the file must keep reading the same secret.
        if re.search(r'\b(data|ephemeral)\b' + W + r'"?vault_', text, re.S) and \
                re.search(r'(path|mount|name|vault\w*)\s*=|\bkv/', added):
            reasons.append(f"{safe(p)}: added path, mount, name or kv/ line in a file that reads Vault")
        for pat, why in ADDED_TOKENS:
            if re.search(pat, added, re.S):
                reasons.append(f"{safe(p)}: {why}")
    print(f"guard examined {len(files)} changed files, {len(planned)} under planned paths")
    print(f"PLANNED_PATHS={len(planned)}")
    if reasons:
        for r in sorted(set(reasons)):
            print("REFUSE " + r.replace("`", "?"))
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # exit 2 means "could not run", which the workflow fails on
        print(f"guard error: {type(e).__name__}: {e}")
        sys.exit(2)
