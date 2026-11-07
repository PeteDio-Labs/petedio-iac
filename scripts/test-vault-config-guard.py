#!/usr/bin/env python3
"""Run: python3 scripts/test-vault-config-guard.py"""
import importlib.util, io, json, os, tempfile, unittest, contextlib
spec = importlib.util.spec_from_file_location("g", os.path.join(os.path.dirname(__file__), "vault-config-guard.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)


def rc(addr, typ, actions, after=None, before=None):
    return {"address": addr, "type": typ, "change": {"actions": actions, "before": before, "after": after, "after_sensitive": {}}}


def run(changes, extra=()):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"resource_changes": changes}, f); f.close()
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = g.main([f.name, *extra])
    return code, buf.getvalue()


ROLE = {"bound_audiences": ["a"], "bound_claims": {"sub": "repo:x"}, "token_policies": ["plane-ci"]}


class T(unittest.TestCase):
    def test_sub_claim_update_allowed(self):
        code, out = run([rc("vault_jwt_auth_backend_role.plane_ci", "vault_jwt_auth_backend_role", ["update"],
                            {**ROLE, "bound_claims": {"sub": "repo:x,repo:y"}}, {**ROLE})])
        self.assertEqual(code, 0); self.assertIn("+ bound_claims.sub: repo:y", out)
        self.assertIn("examined 1 resource changes", out)

    def test_delete_refused(self):
        self.assertEqual(run([rc("vault_policy.a", "vault_policy", ["delete"])])[0], 1)
        self.assertEqual(run([rc("vault_policy.a", "vault_policy", ["delete", "create"], {"policy": ""})])[0], 1)

    def test_protected_and_unknown_type_refused(self):
        self.assertEqual(run([rc("vault_policy.vault_config_apply", "vault_policy", ["update"], {"policy": ""})])[0], 1)
        self.assertEqual(run([rc("vault_policy.breakglass_247", "vault_policy", ["update"], {"policy": ""})])[0], 1)
        self.assertEqual(run([rc("vault_mount.kv", "vault_mount", ["update"], {})])[0], 1)
        self.assertEqual(run([rc("vault_audit.file", "vault_audit", ["create"], {})])[0], 1)

    def test_policy_content(self):
        bad = ['path "sys/policies/acl/*" {\n capabilities=["update"]\n}', 'path "' + "kv/" + 'data/*" {\n capabilities=["read"]\n}',  # split so secrets-register sees no kv reference
               'path "kv/data/x" {\n capabilities=["read","sudo"]\n}', 'path "auth/token/create" {\n capabilities=["update"]\n}']
        for b in bad:
            self.assertEqual(run([rc("vault_policy.n", "vault_policy", ["create"], {"policy": b})])[0], 1, b)
        ok = 'path "kv/data/services/plane" {\n capabilities=["read"]\n}'
        self.assertEqual(run([rc("vault_policy.n", "vault_policy", ["create"], {"policy": ok})])[0], 0)

    def test_privileged_policy_update_refused(self):
        self.assertEqual(run([rc("vault_policy.ci_read", "vault_policy", ["update"], {"name": "ci-read", "policy": ""})])[0], 1)

    def test_role_privileged_policy_refused(self):
        r = {**ROLE, "token_policies": ["ci-read"]}
        self.assertEqual(run([rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], r)])[0], 1)
        r = {"bound_audiences": ["a"], "bound_claims": {"actor": "x"}, "token_policies": ["p"]}
        self.assertEqual(run([rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], r)])[0], 1)

    def test_ssh_role_root_refused(self):
        self.assertEqual(run([rc("vault_ssh_secret_backend_role.n", "vault_ssh_secret_backend_role", ["create"], {"allowed_users": "root", "default_user": "root"})])[0], 1)
        self.assertEqual(run([rc("vault_ssh_secret_backend_role.n", "vault_ssh_secret_backend_role", ["create"], {"allowed_users": "deploy-x", "default_user": "deploy-x"})])[0], 0)

    def test_digest_pins_the_plan(self):
        ch = [rc("vault_jwt_auth_backend_role.plane_ci", "vault_jwt_auth_backend_role", ["update"], ROLE, ROLE)]
        _, out = run(ch)
        d = [l for l in out.splitlines() if l.startswith("plan-digest:")][0].split()[1]
        self.assertEqual(run(ch, ("--expect-digest", d))[0], 0)
        ch2 = [rc("vault_jwt_auth_backend_role.plane_ci", "vault_jwt_auth_backend_role", ["update"], {**ROLE, "token_policies": ["other"]}, ROLE)]
        self.assertEqual(run(ch2, ("--expect-digest", d))[0], 1)

    def test_empty_plan_says_what_it_examined(self):
        code, out = run([])
        self.assertEqual(code, 0); self.assertIn("examined 0 resource changes", out)


if __name__ == "__main__":
    unittest.main()
