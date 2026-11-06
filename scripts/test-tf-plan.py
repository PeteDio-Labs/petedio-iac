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


def check(name, got, want):
    ok = got == want
    print(("PASS " if ok else "FAIL ") + name, "" if ok else f"(got {got}, want {want})")
    return ok


results = [
    check("plain resource passes", guard('resource "x" "y" {}\n'), 0),
    check("local-exec refused", guard('provisioner "local-exec" {}\n'), 1),
    check("external data refused", guard('data "external" "x" {}\n'), 1),
    check("remote module refused", guard('  source = "git::https://x/y"\n'), 1),
    check("local module passes", guard('  source = "../../modules/proxmox-lxc"\n'), 0),
    check("comment mentioning provisioner passes", guard("# no provisioner here\n"), 0),
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
results.append(check("empty state fails", run(sys.executable, S, f.name).returncode, 1))
sys.exit(0 if all(results) else 1)
