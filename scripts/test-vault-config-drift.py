#!/usr/bin/env python3
"""Tests for scripts/vault-config-drift.py (PET-894). Run: python3 scripts/test-vault-config-drift.py"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "vault-config-drift.py"
TF = '''
resource "vault_policy" "a" {
  name = "alpha"
  policy = "x"
}
resource "vault_policy" "dep" {
  for_each = local.hosts
  name = "deploy-${each.key}"
}
resource "vault_jwt_auth_backend_role" "j" {
  role_name = "jwt-one"
}
resource "vault_approle_auth_backend_role" "r" {
  role_name = "role-one"
}
'''


def run(live, tf=TF):
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d)
        (p / "main.tf").write_text(tf)
        (p / "live.json").write_text(json.dumps(live))
        r = subprocess.run([sys.executable, str(SCRIPT), str(p / "live.json"), str(p)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


GOOD = {"policies": ["alpha", "deploy-seerr", "default", "root"], "jwt_roles": ["jwt-one"], "approle_roles": ["role-one"]}


class Drift(unittest.TestCase):
    def test_match_and_templates_and_builtins(self):
        rc, out = run(GOOD)
        self.assertEqual(rc, 0, out)
        self.assertIn("compared 4 live names with 4 declarations", out)

    def test_undeclared_policy(self):
        rc, out = run({**GOOD, "policies": GOOD["policies"] + ["stray"]})
        self.assertEqual(rc, 1)
        self.assertIn("in-vault-not-declared=stray", out)

    def test_missing_declared_role(self):
        rc, out = run({**GOOD, "jwt_roles": []})
        self.assertEqual(rc, 1)
        self.assertIn("declared-not-in-vault=jwt-one", out)

    def test_one_unread_listing_fails(self):
        rc, out = run({**GOOD, "approle_roles": None})
        self.assertEqual(rc, 1)
        self.assertIn("approle_roles: unread", out)

    def test_all_unread_is_not_a_pass(self):
        rc, out = run({"policies": None, "jwt_roles": None, "approle_roles": None})
        self.assertEqual(rc, 3)
        self.assertIn("compared 0 names", out)

    def test_no_declarations_is_a_refusal_not_a_pass(self):
        rc, out = run(GOOD, tf="# empty\n")
        self.assertEqual(rc, 2)

    def test_bad_input(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "live.json").write_text("not json")
            r = subprocess.run([sys.executable, str(SCRIPT), str(pathlib.Path(d) / "live.json")], capture_output=True)
            self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
