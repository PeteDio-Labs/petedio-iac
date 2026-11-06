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

# Whole-file tokens, checked in every changed Terraform file.
FILE_TOKENS = [
    (r'\bprovisioner\b|\blocal-exec\b|\bremote-exec\b', "provisioner"),
    (r'"external"|"http"|"archive"|"local"|"dns"|"tls"', "data source of an execution or network provider"),
    (r'\bterraform_remote_state\b', "remote state read"),
    (r'\bprovider\s*"|\brequired_providers\b', "provider configuration"),
    (r'\bproviders\s*=', "provider passed to a module"),
    (r'\bbackend\s*"', "backend block"),
    # A function call may have comments between the name and "(" in HCL.
    (r'\b(file|templatefile|fileset|filebase64|filemd5|filesha1|filesha256|pathexpand|nonsensitive)\b'
     r'\s*(?:/\*.*?\*/\s*|(?:#|//)[^\n]*\n\s*)*\(', "file read or nonsensitive()"),
]
# Added lines only: module sources that already exist stay legal.
ADDED_SOURCE = re.compile(r'^\s*source\s*=\s*"(?!\.\./\.\./modules/(proxmox-lxc|postgres-db|cloudflare-ingress)")')
FORBIDDEN_PATH = [
    (r'(^|/)\.terraform\.lock\.hcl$', "provider lock file"),
    (r'(^|/)(override|.*_override)\.tf(\.json)?$', "override file"),
    (r'\.tf\.json$', "JSON configuration"),
    (r'(^|/)\.terraformrc$|\.tfrc$', "CLI config file"),
    (r'(^|/)backend\.tf$', "backend configuration"),
    (r'^environments/homelab/(providers|variables|versions)\.tf$', "defines a provider destination"),
    (r'\.tfvars(\.json)?$|\.auto\.tfvars', "variable values file"),
    (r'^modules/baremetal-host/', "module that holds a local-exec provisioner"),
]
ALLOWED_ROOTS = re.compile(
    r'^(environments/homelab/[^/]+$|modules/(proxmox-lxc|postgres-db|cloudflare-ingress)/)')
PLANNED = re.compile(r'^(environments/homelab/(?!vault-config/)|modules/)')
TERRAFORM_FILE = re.compile(r'\.(tf|tfvars|hcl)$|\.tf\.json$')


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
    planned = [p for p in files if PLANNED.match(p)]
    reasons = []
    for mode, status, p in entries:
        if mode in ("120000", "160000") and status != "D":
            reasons.append(f"{p}: symlink or submodule")
        for pat, why in FORBIDDEN_PATH:
            if re.search(pat, p):
                reasons.append(f"{p}: {why}")
        if planned and TERRAFORM_FILE.search(p) and not ALLOWED_ROOTS.match(p) \
                and not p.startswith("environments/homelab/vault-config/"):
            reasons.append(f"{p}: Terraform file outside the planned roots")
        if status == "D" or not TERRAFORM_FILE.search(p):
            continue
        body = git(repo, "show", f"{head}:{p}")
        if body.returncode != 0:
            print(f"guard error: cannot read {p} at {head}")
            return 2
        text = body.stdout.decode(errors="replace")
        for pat, why in FILE_TOKENS:
            if re.search(pat, text, re.S):
                reasons.append(f"{p}: {why}")
        d = git(repo, "diff", "-U0", f"{base}..{head}", "--", p)
        for line in d.stdout.decode(errors="replace").splitlines():
            if line.startswith("+") and not line.startswith("+++") and ADDED_SOURCE.search(line[1:]):
                reasons.append(f"{p}: added source other than the three reviewed modules")
    print(f"guard examined {len(files)} changed files, {len(planned)} under planned paths")
    print(f"PLANNED_PATHS={len(planned)}")
    if reasons:
        for r in sorted(set(reasons)):
            print(f"REFUSE {r}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
