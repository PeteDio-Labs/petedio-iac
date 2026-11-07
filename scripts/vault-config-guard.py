#!/usr/bin/env python3
"""Refuse a vault-config plan that a person must apply by hand (PET: gated vault-config apply).

  vault-config-guard.py plan.json [--expect-digest HEX] [--digest-out FILE]

plan.json is `terraform show -json tfplan`. The guard exits 0 only when every change in the plan
is one the gated workflow may apply, and it prints what it examined: how many resource changes it
read, which it allowed, and a digest of the allowed set. The apply job re-plans and passes the plan
job's digest to --expect-digest, so what Pedro approved is what applies.

The gate is deny by default:
  * Only a create or update. Any delete or replace is refused.
  * Only the types in ALLOWED_TYPES. Any other type is refused.
  * Never a protected address, such as the apply role itself or the break-glass policy.
  * A policy may not touch sys/, auth/ or identity/, grant sudo, or open a whole mount.
  * A JWT role may not attach a privileged policy, and must bind a repository, sub or workflow_ref.
A refused change stays a Mac step (scripts/apply-vault-config.sh).
"""
import hashlib
import json
import re
import sys

ALLOWED_TYPES = {"vault_policy", "vault_jwt_auth_backend_role", "vault_ssh_secret_backend_role"}
PROTECTED_ADDR = re.compile(
    r"^(vault_policy|vault_jwt_auth_backend_role)\.(vault_config_\w+|breakglass\w*|claude_ops\w*)(\[.*\])?$"
    r"|^vault_ssh_secret_backend_role\.(lab_runner|pedro)(\[.*\])?$"
)
PRIVILEGED_POLICIES = {
    "vault-config-apply", "vault-config-plan", "breakglass-247", "terraform", "ansible", "ansible-247",
    "ci-read", "claude-ops", "claude-247-deploy", "lab-action-read", "root",
}
FORBIDDEN_POLICY_PATH = re.compile(r"^(sys|auth|identity|ssh-client-signer/(config|roles))(/|$)|^(\*|\+|kv/\*|kv/data/\*|kv/data/\+)$")
PATH_BLOCK = re.compile(r'path\s+"([^"]+)"\s*\{(.*?)\}', re.S)
ROLE_BIND_KEYS = ("repository", "sub", "workflow_ref")


def policy_problems(text):
    p = []
    for path, body in PATH_BLOCK.findall(text or ""):
        if FORBIDDEN_POLICY_PATH.search(path):
            p.append(f'policy path "{path}" is outside what the gated apply may grant')
        if re.search(r'"sudo"', body):
            p.append(f'policy path "{path}" grants sudo')
    return p


def role_problems(after):
    p = []
    bad = sorted(set(after.get("token_policies") or []) & PRIVILEGED_POLICIES)
    if bad:
        p.append(f"role attaches privileged policies {bad}")
    claims = after.get("bound_claims") or {}
    if not any(k in claims for k in ROLE_BIND_KEYS):
        p.append("role binds none of repository, sub or workflow_ref")
    if not after.get("bound_audiences"):
        p.append("role has no bound_audiences")
    return p


def ssh_role_problems(after):
    users = {u.strip() for u in str(after.get("allowed_users") or "").split(",")}
    return ["ssh role can sign for root or any user"] if users & {"root", "*", ""} or "root" in str(after.get("default_user")) else []


def examine(plan):
    allowed, refused, noop = [], [], 0
    for rc in plan.get("resource_changes", []):
        acts = rc["change"]["actions"]
        if acts in (["no-op"], ["read"]):
            noop += 1
            continue
        addr, typ = rc["address"], rc["type"]
        why = []
        if "delete" in acts:
            why.append(f"actions {acts} remove or replace a live resource")
        if typ not in ALLOWED_TYPES:
            why.append(f"type {typ} is not in the allowed set")
        if PROTECTED_ADDR.match(addr):
            why.append("protected address")
        after = rc["change"].get("after") or {}
        if not why and typ == "vault_policy":
            if after.get("name") in PRIVILEGED_POLICIES:
                why.append(f"policy {after.get('name')} is privileged; change it with scripts/apply-vault-config.sh")
            why += policy_problems(after.get("policy"))
        if not why and typ == "vault_jwt_auth_backend_role":
            why += role_problems(after)
        if not why and typ == "vault_ssh_secret_backend_role":
            why += ssh_role_problems(after)
        (refused if why else allowed).append((rc, why))
    return allowed, refused, noop


def digest(allowed):
    rows = sorted(
        (rc["address"], rc["change"]["actions"], rc["change"].get("after"), rc["change"].get("after_sensitive"))
        for rc, _ in allowed
    )
    return hashlib.sha256(json.dumps(rows, sort_keys=True, default=str).encode()).hexdigest()


def show_diff(rc):
    ch = rc["change"]
    before, after = ch.get("before") or {}, ch.get("after") or {}
    sens = ch.get("after_sensitive") or {}
    for k in sorted(set(before) | set(after)):
        if sens.get(k) or before.get(k) == after.get(k):
            continue
        if k == "bound_claims":
            b, a = before.get(k) or {}, after.get(k) or {}
            for ck in sorted(set(a) | set(b)):
                bs, as_ = set(str(b.get(ck, "")).split(",")) - {""}, set(str(a.get(ck, "")).split(",")) - {""}
                for v in sorted(as_ - bs):
                    print(f"      + bound_claims.{ck}: {v}")
                for v in sorted(bs - as_):
                    print(f"      - bound_claims.{ck}: {v}")
        elif k in ("token_policies", "policy"):
            print(f"      ~ {k} changed" if k == "policy" else f"      ~ {k}: {before.get(k)} -> {after.get(k)}")
        else:
            print(f"      ~ {k} changed")


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    with open(argv[0]) as fh:
        plan = json.load(fh)
    expect = argv[argv.index("--expect-digest") + 1] if "--expect-digest" in argv else None
    out = argv[argv.index("--digest-out") + 1] if "--digest-out" in argv else None
    allowed, refused, noop = examine(plan)
    total = len(plan.get("resource_changes", []))
    print(f"guard: examined {total} resource changes: {len(allowed)} to apply, {len(refused)} refused, {noop} unchanged")
    for rc, _ in allowed:
        print(f"  ok  {rc['address']} {rc['change']['actions']}")
        show_diff(rc)
    for rc, why in refused:
        print(f"  REFUSED  {rc['address']} {rc['change']['actions']}")
        for w in why:
            print(f"      {w}")
    d = digest(allowed)
    print(f"plan-digest: {d}")
    if out:
        open(out, "w").write(d)
    if refused:
        print("guard: refused. These changes need scripts/apply-vault-config.sh on a trusted machine.")
        return 1
    if expect and expect != d:
        print(f"guard: the plan changed since it was approved (expected {expect}, got {d}). Nothing applied.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
