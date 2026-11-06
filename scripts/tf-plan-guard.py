#!/usr/bin/env python3
"""Decide whether a pull request's Terraform may be planned on the homelab runner (PET-866).

A plan runs the pull request's own Terraform with the runner's credentials, and this repo is
public. The workflow therefore plans automatically only when the pull request adds nothing that
makes Terraform run code or fetch code from outside this repo. Anything else gets a comment that
says an operator must plan it locally.

Usage: tf-plan-guard.py <checkout> [--base REV] [--head REV]

<checkout> is a git checkout of the merge ref. Defaults compare HEAD^1 (main) with HEAD.
Exit 0 means safe to plan, 1 means refuse, 2 means the guard could not read the diff. Exit 2
is a failure, never a pass. Prints what it examined on every path.
"""
import re
import subprocess
import sys

# Added lines that make Terraform execute or fetch something.
FORBIDDEN_LINE = [
    (r'\bprovisioner\b', "provisioner block"),
    (r'\blocal-exec\b|\bremote-exec\b', "exec provisioner"),
    (r'\bdata\s+"external"', 'data "external"'),
    (r'\bdata\s+"http"', 'data "http"'),
    (r'\bexternal\b\s*=\s*\{', "external provider"),
    (r'^\s*source\s*=\s*"(?!\.\./\.\./modules/(proxmox-lxc|postgres-db|cloudflare-ingress)")',
     "source other than the three reviewed modules"),
    (r'^\s*provider\s+"|\brequired_providers\b', "provider configuration"),
    (r'\bterraform_remote_state\b', "remote state read"),
    (r'\bnonsensitive\s*\(', "nonsensitive()"),
    (r'\b(file|templatefile|fileset|filebase64|pathexpand)\s*\(', "local file read"),
    (r'\bprovider_installation\b|\bplugin_cache\b', "CLI config"),
    (r'\bbackend\s+"', "backend block"),
    (r'\bendpoints?\s*=', "backend or provider endpoint"),
]
# Paths whose any change needs a human plan.
FORBIDDEN_PATH = [
    (r'(^|/)\.terraform\.lock\.hcl$', "provider lock file"),
    (r'(^|/)(override|.*_override)\.tf(\.json)?$', "override file"),
    (r'\.tf\.json$', "JSON configuration"),
    (r'(^|/)\.terraformrc$|\.tfrc$', "CLI config file"),
    (r'(^|/)backend\.tf$', "backend configuration"),
    # These define where the provider sends the credentials (PET-866 review, P1).
    (r'^environments/homelab/(providers|variables|versions)\.tf$', "defines a provider destination"),
    (r'\.tfvars(\.json)?$|\.auto\.tfvars', "variable values file"),
    (r'^modules/baremetal-host/', "module that holds a local-exec provisioner"),
]
# The only directories the homelab root may load. A Terraform file anywhere else in a PR that
# also changes the planned roots is refused, because a root could point a module at it.
ALLOWED_ROOTS = re.compile(
    r'^(environments/homelab/[^/]+$|modules/(proxmox-lxc|postgres-db|cloudflare-ingress)/)')
PLANNED = re.compile(r'^(environments/homelab/(?!vault-config/)|modules/)')
TERRAFORM_FILE = re.compile(r'\.(tf|tfvars|hcl)$')


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


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
    names = git(repo, "diff", "--name-only", f"{base}..{head}")
    if names.returncode != 0:
        print(f"guard error: git diff failed: {names.stderr.strip()}")
        return 2
    files = [f for f in names.stdout.splitlines() if f]
    if not files:
        print(f"guard error: {base}..{head} changed 0 files, so nothing was examined")
        return 2
    planned = [f for f in files if PLANNED.match(f)]
    reasons = []
    for f in files:
        for pat, why in FORBIDDEN_PATH:
            if re.search(pat, f):
                reasons.append(f"{f}: {why}")
    if planned:
        for f in files:
            if (TERRAFORM_FILE.search(f) or f.endswith(".tf.json")) and not ALLOWED_ROOTS.match(f) \
                    and not f.startswith("environments/homelab/vault-config/"):
                reasons.append(f"{f}: Terraform file outside the planned roots")
    for f in planned:
        if not TERRAFORM_FILE.search(f):
            continue
        d = git(repo, "diff", "-U0", f"{base}..{head}", "--", f)
        if d.returncode != 0:
            print(f"guard error: git diff failed for {f}")
            return 2
        for line in d.stdout.splitlines():
            if not line.startswith("+") or line.startswith("+++"):
                continue
            body = line[1:]
            if body.lstrip().startswith(("#", "//")):
                continue
            for pat, why in FORBIDDEN_LINE:
                if re.search(pat, body):
                    reasons.append(f"{f}: added line has {why}")
    print(f"guard examined {len(files)} changed files, {len(planned)} under planned paths")
    print(f"PLANNED_PATHS={len(planned)}")
    if reasons:
        for r in sorted(set(reasons)):
            print(f"REFUSE {r}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
