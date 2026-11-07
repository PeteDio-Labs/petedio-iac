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
  * A policy may grant only read and list on kv/(services|db)/<name>, plus ssh signing for deploy-*.
    kv/admin, kv/iac and any other mount stay with scripts/apply-vault-config.sh.
  * A JWT role binds the allowlisted repository, main only, and a token_ttl of 900 seconds or less.
  * An SSH role pins source-address to the two runners, a ttl of 1800 seconds or less, and no
    caller override of critical options or extensions.
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
# A JWT role may attach only these policies, or the policies it already had. The set is an
# allowlist: a policy added to vault-config later is not attachable until a reviewed PR lists it.
ROLE_POLICY_ALLOW = re.compile(r"^(plane-ci|secrets-register|deploy-[a-z0-9-]+)$")
SSH_ROLE_NAME = re.compile(r"^deploy-[a-z0-9-]+$")
SSH_SIGN_PATH = re.compile(r"^ssh-client-signer/sign/deploy-[a-z0-9-]+$")
PRIVILEGED_POLICIES = {
    "vault-config-apply", "vault-config-plan", "breakglass-247", "terraform", "ansible", "ansible-247",
    "ci-read", "claude-ops", "claude-247-deploy", "lab-action-read", "root",
}
FORBIDDEN_POLICY_PATH = re.compile(r"^(sys|auth|identity)(/|$)|^(\*|\+|kv/\*|kv/data/\*|kv/data/\+)$")
PATH_BLOCK = re.compile(r'path\s+"([^"]+)"\s*\{(.*?)\}', re.S)
ROLE_BIND_KEYS = ("repository", "sub", "workflow_ref")
# A policy this path may write can grant only these. Everything else (kv/admin, kv/iac, any other
# mount) is a path the guard cannot call safe, so it goes through scripts/apply-vault-config.sh.
KV_GRANT = re.compile(r"^kv/(data|metadata)/(services|db)/[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)*$")
SAFE_CAPS = {"read", "list"}
# A policy the gated apply may create with paths outside KV_GRANT. The guard pins each one to an
# exact path set: the policy may drop a path but never add one, and grants read only. A change to
# this table is a change to this file, which a reviewer reads.
PINNED_POLICIES = {
    "deploy-terraform-plan": {
        "kv/data/iac/minio", "kv/data/iac/proxmox", "kv/data/iac/cloudflare", "kv/data/iac/authentik",
        "kv/data/admin/postgres", "kv/data/db/plane", "kv/data/services/water-fast",
    },
}
ALLOWED_REPOS = {"PeteDio-Labs/petedio-iac"}
SUB_OK = re.compile(r"^repo:PeteDio-Labs(@\d+)?/[a-z0-9-]+(@\d+)?:(ref:refs/heads/main|pull_request)$")
MAX_TTL = 900
SSH_SOURCES = "192.168.50.232/32,192.168.50.233/32"


def policy_problems(text, name=None):
    text = text or ""
    pinned = PINNED_POLICIES.get(name)
    p = []
    if text.lstrip().startswith("{"):
        return ["JSON-format policy: the guard reads HCL only"]
    body_text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith(("#", "//")))
    blocks = PATH_BLOCK.findall(body_text)
    if len(blocks) != len(re.findall(r'\bpath\s*"', body_text)) or re.search(r"\bpath\s*'", body_text):
        p.append("policy has a path stanza the guard cannot parse")
    for raw, body in blocks:
        if "\\" in raw or "${" in raw or "%{" in raw or not raw.isascii():
            p.append(f'policy path "{raw}" uses an escape or interpolation the guard cannot decode')
            continue
        path = raw.lstrip("/")
        first = path.split("/", 1)[0]
        if re.search(r"[*+]", first):
            p.append(f'policy path "{raw}" has a wildcard in its first segment')
        if "+" in path:
            p.append(f'policy path "{raw}" uses a + segment')
        if path.startswith("ssh-client-signer") and not SSH_SIGN_PATH.match(path):
            p.append(f'policy path "{raw}": only ssh-client-signer/sign/deploy-<name> may be granted')
        if FORBIDDEN_POLICY_PATH.search(path):
            p.append(f'policy path "{raw}" is outside what the gated apply may grant')
        elif path.startswith("kv/"):
            if pinned is not None and path in pinned:
                pass
            elif not KV_GRANT.match(path):
                p.append(f'policy path "{raw}": only kv/data|metadata/(services|db)/<name> may be granted')
            caps = set(re.findall(r'"([a-z]+)"', body))
            if not caps or caps - SAFE_CAPS:
                p.append(f'policy path "{raw}": only read and list may be granted on kv')
        elif not path.startswith("ssh-client-signer/"):
            p.append(f'policy path "{raw}" is on a mount the gated apply may not grant')
        if re.search(r'"sudo"', body):
            p.append(f'policy path "{raw}" grants sudo')
    return p


def role_problems(after, before=None):
    p = []
    pols = after.get("token_policies")
    if pols is None:
        p.append("token_policies is not known at plan time")
    had = set((before or {}).get("token_policies") or [])
    bad = sorted(x for x in (pols or []) if x not in had and not ROLE_POLICY_ALLOW.match(x))
    bad += sorted(set(pols or []) & PRIVILEGED_POLICIES - had)
    if bad:
        p.append(f"role attaches policies outside the allowlist: {sorted(set(bad))}")
    if after.get("bound_claims_type", "string") != "string":
        p.append("bound_claims_type must be string (no glob matching)")
    for k, v in (after.get("bound_claims") or {}).items():
        if re.search(r"[*?]", str(v)):
            p.append(f"bound_claims.{k} contains a wildcard")
    claims = after.get("bound_claims") or {}
    if not any(k in claims for k in ROLE_BIND_KEYS):
        p.append("role binds none of repository, sub or workflow_ref")
    if not after.get("bound_audiences"):
        p.append("role has no bound_audiences")
    repo = claims.get("repository")
    if repo is not None and str(repo) not in ALLOWED_REPOS:
        p.append(f"bound_claims.repository {repo} is not an allowlisted repository")
    if "ref" in claims and str(claims["ref"]) != "refs/heads/main":
        p.append("bound_claims.ref must be refs/heads/main")
    if "sub" in claims:
        bad = [x for x in str(claims["sub"]).split(",") if not SUB_OK.match(x)]
        if bad:
            p.append(f"bound_claims.sub has entries outside repo:PeteDio-Labs/<name>:(ref:refs/heads/main|pull_request): {bad[:3]}")
    elif "ref" not in claims:
        p.append("role binds no ref or sub, so a branch other than main could mint it")
    if "sub" not in claims and "workflow_ref" not in claims:
        p.append("role binds no workflow_ref, so any workflow on main could mint it")
    for k in ("token_ttl", "token_max_ttl"):
        v = after.get(k)
        if k == "token_ttl" and not v:
            p.append("token_ttl must be set (the Vault default is 32 days)")
        if v and int(v) > MAX_TTL:
            p.append(f"{k} {v} exceeds {MAX_TTL} seconds")
    return p


def ssh_role_problems(after):
    name, users = str(after.get("name") or ""), str(after.get("allowed_users") or "")
    p = []
    if not SSH_ROLE_NAME.match(name):
        p.append("ssh role name must match deploy-<name>")
    if users != name or users != str(after.get("default_user") or ""):
        p.append("ssh role allowed_users and default_user must both equal the role name (no list, no glob)")
    if after.get("key_type") != "ca" or not after.get("allow_user_certificates"):
        p.append("ssh role must be key_type ca with allow_user_certificates")
    if after.get("allow_user_key_ids"):
        p.append("ssh role must not allow user key ids")
    if (after.get("default_critical_options") or {}) != {"source-address": SSH_SOURCES}:
        p.append(f"ssh role default_critical_options must be exactly source-address={SSH_SOURCES}")
    if str(after.get("allowed_critical_options") or "") != "petedio-no-overrides":
        p.append("ssh role allowed_critical_options must be petedio-no-overrides (no caller override)")
    if str(after.get("allowed_extensions") or ""):
        p.append("ssh role allowed_extensions must be empty")
    for k in ("ttl", "max_ttl"):
        try:
            ok = 0 < int(str(after.get(k) or "0")) <= 1800
        except ValueError:
            ok = False
        if not ok:
            p.append(f"ssh role {k} must be 1..1800 seconds")
    return p


# Attributes whose value the guard reads. If Terraform cannot know one at plan time, the guard
# cannot judge it, and a hash of an unresolved value approves nothing.
CHECKED = {
    "vault_policy": ("name", "policy"),
    "vault_jwt_auth_backend_role": ("token_policies", "bound_claims", "bound_claims_type", "bound_audiences", "token_ttl", "token_max_ttl"),
    "vault_ssh_secret_backend_role": ("name", "allowed_users", "default_user", "key_type", "allow_user_certificates",
                                      "default_critical_options", "allowed_critical_options", "allowed_extensions",
                                      "ttl", "max_ttl"),
}


def has_unknown(v):
    """after_unknown marks a list as [false] when every element is known. Only a true counts."""
    if isinstance(v, dict):
        return any(has_unknown(x) for x in v.values())
    if isinstance(v, list):
        return any(has_unknown(x) for x in v)
    return v is True


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
        unknown = rc["change"].get("after_unknown") or {}
        for attr in CHECKED.get(typ, ()):
            if has_unknown(unknown.get(attr)):
                why.append(f"{attr} is unknown until apply, so the guard cannot read it")
        if not why and typ == "vault_policy":
            if after.get("name") in PRIVILEGED_POLICIES:
                why.append(f"policy {after.get('name')} is privileged; change it with scripts/apply-vault-config.sh")
            why += policy_problems(after.get("policy"), after.get("name"))
        if not why and typ == "vault_jwt_auth_backend_role":
            why += role_problems(after, rc["change"].get("before"))
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


def _caps(body):
    return ",".join(sorted(re.findall(r'"([a-z]+)"', body)))


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
        elif k == "policy":
            bp = {m[0]: _caps(m[1]) for m in PATH_BLOCK.findall(before.get(k) or "")}
            ap = {m[0]: _caps(m[1]) for m in PATH_BLOCK.findall(after.get(k) or "")}
            for path in sorted(set(ap) | set(bp)):
                if bp.get(path) != ap.get(path):
                    print(f"      policy path {path}: {bp.get(path, '-')} -> {ap.get(path, '-')}")
        elif k == "token_policies":
            print(f"      ~ {k}: {before.get(k)} -> {after.get(k)}")
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
