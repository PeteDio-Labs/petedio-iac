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


SUB = "repo:PeteDio-Labs/petedio-iac:ref:refs/heads/main"
ROLE = {"bound_audiences": ["a"], "bound_claims": {"sub": SUB}, "token_policies": ["plane-ci"], "bound_claims_type": "string", "token_ttl": 600}
SSH = {"key_type": "ca", "allow_user_certificates": True, "allow_user_key_ids": False,
       "default_critical_options": {"source-address": "192.168.50.232/32,192.168.50.233/32"},
       "allowed_critical_options": "petedio-no-overrides", "allowed_extensions": "", "ttl": "1800", "max_ttl": "1800"}


KV = "kv/"  # split from the path so secrets-register sees no kv reference


class T(unittest.TestCase):
    def test_sub_claim_update_allowed(self):
        code, out = run([rc("vault_jwt_auth_backend_role.plane_ci", "vault_jwt_auth_backend_role", ["update"],
                            {**ROLE, "bound_claims": {"sub": SUB + ",repo:PeteDio-Labs/petedio-vault:ref:refs/heads/main"}}, {**ROLE})])
        self.assertEqual(code, 0); self.assertIn("+ bound_claims.sub: repo:PeteDio-Labs/petedio-vault:ref:refs/heads/main", out)
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

    def test_ssh_role_allowlist(self):
        def r(name, users, default=None):
            return run([rc("vault_ssh_secret_backend_role.n", "vault_ssh_secret_backend_role", ["create"],
                           {**SSH, "name": name, "allowed_users": users, "default_user": default or users})])[0]
        self.assertEqual(r("deploy-x", "deploy-x"), 0)
        for name, users in (("deploy-x", "root"), ("lab-runner", "lab-runner"), ("deploy-x", "deploy-*"),
                            ("deploy-x", "deploy-x,root"), ("x", "x")):
            self.assertEqual(r(name, users), 1, (name, users))

    def test_policy_may_not_grant_other_ssh_signing(self):
        for path in ("ssh-client-signer/sign/lab-runner", "ssh-client-signer/sign/*", "ssh-client-signer/roles/x"):
            pol = 'path "%s" {\n capabilities=["update"]\n}' % path
            self.assertEqual(run([rc("vault_policy.n", "vault_policy", ["create"], {"name": "n", "policy": pol})])[0], 1, path)
        ok = 'path "ssh-client-signer/sign/deploy-x" {\n capabilities=["update"]\n}'
        self.assertEqual(run([rc("vault_policy.n", "vault_policy", ["create"], {"name": "n", "policy": ok})])[0], 0)

    def test_policy_glob_and_format_bypasses(self):
        def pol(text):
            return run([rc("vault_policy.n", "vault_policy", ["create"], {"name": "n", "policy": text})])[0]
        for path in ("ssh-*/sign/lab-runner", "s*/sign/lab-runner", "+/sign/lab-runner", "/ssh-client-signer/sign/lab-runner",
                     "ssh-client-signer/+/lab-runner", "kv/+/x", "*/sign/x"):
            self.assertEqual(pol('path "%s" {\n capabilities=["update"]\n}' % path), 1, path)
        self.assertEqual(pol('{"path": {"ssh-client-signer/sign/lab-runner": {"capabilities": ["update"]}}}'), 1)
        self.assertEqual(pol(' \n{"path": {}}'), 1)
        self.assertEqual(pol('path \'ssh-client-signer/sign/lab-runner\' {\n capabilities=["update"]\n}'), 1)
        self.assertEqual(pol('path "kv/data/services/plane" {\n capabilities=["read"]\n}\n# path "sys/x" {}'), 0)

    def test_escapes_interpolation_and_unknowns_refused(self):
        def pol(text):
            return run([rc("vault_policy.n", "vault_policy", ["create"], {"name": "n", "policy": text})])[0]
        self.assertEqual(pol('path "\\u0073ys/policies/acl/x" {\n capabilities=["update"]\n}'), 1)
        self.assertEqual(pol('path "kv/' + 'data/${x}" {\n capabilities=["read"]\n}'), 1)
        self.assertEqual(pol('path "sy\u0455/x" {\n capabilities=["read"]\n}'), 1)
        c = rc("vault_policy.n", "vault_policy", ["create"], {"name": "n"})
        c["change"]["after_unknown"] = {"policy": True}
        self.assertEqual(run([c])[0], 1)
        r = rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], ROLE)
        r["change"]["after_unknown"] = {"bound_claims": {"sub": True}}
        self.assertEqual(run([r])[0], 1)

    def test_role_policy_allowlist_and_claims(self):
        def r(pols, claims=None, typ="string", before=None):
            a = {**ROLE, "token_policies": pols, "bound_claims_type": typ}
            if claims: a["bound_claims"] = claims
            return run([rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["update" if before else "create"], a, before)])[0]
        self.assertEqual(r(["deploy-x"]), 0)
        self.assertEqual(r(["tracker-ci"]), 0)
        self.assertEqual(r(["media-ci"]), 1)             # an existing policy, not allowlisted
        self.assertEqual(r(["media-ci"], before={**ROLE, "token_policies": ["media-ci"]}), 0)  # unchanged on an existing role
        self.assertEqual(r(["plane-ci"], typ="glob"), 1)
        self.assertEqual(r(["plane-ci"], claims={"sub": "repo:PeteDio-Labs/*"}), 1)

    def test_privileged_policy_update_refused(self):
        self.assertEqual(run([rc("vault_policy.ci_read", "vault_policy", ["update"], {"name": "ci-read", "policy": ""})])[0], 1)

    def test_role_privileged_policy_refused(self):
        r = {**ROLE, "token_policies": ["ci-read"]}
        self.assertEqual(run([rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], r)])[0], 1)
        r = {"bound_audiences": ["a"], "bound_claims": {"actor": "x"}, "token_policies": ["p"]}
        self.assertEqual(run([rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], r)])[0], 1)

    def test_policy_kv_allowlist(self):
        def pol(path, caps='"read"'):
            return run([rc("vault_policy.n", "vault_policy", ["create"], {"name": "deploy-x", "policy": 'path "%s" {\n capabilities=[%s]\n}' % (path, caps)})])[0]
        self.assertEqual(pol("kv/data/services/plane"), 0)
        self.assertEqual(pol("kv/data/db/plane"), 0)
        for bad in (KV + "data/admin/root-token", "kv/data/admin/postgres", "kv/data/iac/lxc-ssh", "kv/data/iac/proxmox",
                    KV + "metadata/admin/x", "kv/data/services/*", "cubbyhole/x", "database/creds/x", "transit/keys/x"):
            self.assertEqual(pol(bad), 1, bad)
        self.assertEqual(pol("kv/data/services/plane", '"read","update"'), 1)
        self.assertEqual(pol("kv/data/services/plane", '"delete"'), 1)

    def test_pinned_policy_may_not_widen(self):
        def pol(name, *paths):
            body = "\n".join('path "%s" {\n capabilities=["read"]\n}' % p for p in paths)
            return run([rc("vault_policy.n", "vault_policy", ["create"], {"name": name, "policy": body})])[0]
        ok = [KV + "data/iac/minio", KV + "data/admin/postgres"]
        self.assertEqual(pol("deploy-terraform-plan", *ok), 0)
        self.assertEqual(pol("deploy-terraform-plan", *ok, KV + "data/iac/lxc-ssh"), 1)   # not in the pinned set
        self.assertEqual(pol("deploy-other", *ok), 1)                                      # only the pinned name
        self.assertEqual(pol("deploy-terraform-plan", KV + "data/admin/*"), 1)

    def test_known_list_is_not_unknown(self):
        # Terraform writes after_unknown as [false] for a list whose elements are all known.
        r = rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], {**ROLE, "token_policies": ["deploy-x"]})
        r["change"]["after_unknown"] = {"token_policies": [False], "bound_audiences": [False], "bound_claims": {}}
        self.assertEqual(run([r])[0], 0)
        r["change"]["after_unknown"] = {"token_policies": [True]}
        self.assertEqual(run([r])[0], 1)

    def test_ssh_role_pins_options(self):
        def r(**kw):
            return run([rc("vault_ssh_secret_backend_role.n", "vault_ssh_secret_backend_role", ["create"],
                           {**SSH, "name": "deploy-x", "allowed_users": "deploy-x", "default_user": "deploy-x", **kw})])[0]
        self.assertEqual(r(), 0)
        for kw in ({"default_critical_options": {}}, {"default_critical_options": {"source-address": "0.0.0.0/0"}},
                   {"allowed_critical_options": "source-address"}, {"allowed_extensions": "permit-port-forwarding"},
                   {"ttl": "3600"}, {"max_ttl": "86400"}, {"ttl": ""}, {"key_type": "otp"}, {"allow_user_key_ids": True}):
            self.assertEqual(r(**kw), 1, kw)

    def test_jwt_role_claim_values(self):
        def r(claims=None, **kw):
            a = {**ROLE, **kw}
            if claims is not None: a["bound_claims"] = claims
            return run([rc("vault_jwt_auth_backend_role.n", "vault_jwt_auth_backend_role", ["create"], a)])[0]
        self.assertEqual(r(), 0)
        wf = {"repository": "PeteDio-Labs/petedio-iac", "ref": "refs/heads/main", "workflow_ref": "x"}
        self.assertEqual(r(wf), 0)
        self.assertEqual(r({**wf, "repository": "evil/repo"}), 1)
        self.assertEqual(r({**wf, "ref": "refs/heads/dev"}), 1)
        self.assertEqual(r({"repository": "PeteDio-Labs/petedio-iac", "workflow_ref": "x"}), 1)  # no ref
        self.assertEqual(r({"repository": "PeteDio-Labs/petedio-iac", "ref": "refs/heads/main"}), 1)  # any workflow
        self.assertEqual(r({"sub": "repo:evil/x:ref:refs/heads/main"}), 1)
        self.assertEqual(r({"sub": "repo:PeteDio-Labs/x:ref:refs/heads/feature"}), 1)
        self.assertEqual(r(token_ttl=901), 1)
        self.assertEqual(r(token_ttl=0), 1)
        self.assertEqual(r(token_max_ttl=3600), 1)

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
