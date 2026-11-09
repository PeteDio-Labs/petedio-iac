#!/usr/bin/env python3
"""test-keys.py: drive scripts/keys.py against a fake Vault and a fake Cloudflare.

No network and no credentials. It proves the parts a live run cannot show safely:
  - sync creates a token per new agent, writes the one-line header to Vault, and prints no secret
  - a failed Vault write deletes the token it just created
  - sync revokes an agent removed from callers.yml, in Cloudflare and in Vault
  - sync refuses when the plan digest changed after approval
  - rotate keeps a 24-hour overlap and writes the new secret
Run: python3 scripts/test-keys.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("keys", os.path.join(HERE, "keys.py"))
keys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keys)

SECRET = "f" * 64


class Fake:
    def __init__(self, fail_vault_write: bool = False) -> None:
        self.vault: dict[str, dict] = {}   # name -> {"data": ..., "custom": ..., "version": n}
        self.cf: dict[str, dict] = {}      # id -> token
        self.n = 0
        self.fail_vault_write = fail_vault_write
        self.rotate_bodies: list[dict] = []

    def __call__(self, method, url, headers, body, ctx):
        if url.startswith("https://vault"):
            return self.vault_call(method, url.split("/v1/", 1)[1], body)
        return self.cf_call(method, url, body)

    def vault_call(self, method, path, body):
        meta, data = f"{keys.VAULT_MOUNT}/metadata/{keys.VAULT_PREFIX}", f"{keys.VAULT_MOUNT}/data/{keys.VAULT_PREFIX}"
        if path == f"{keys.VAULT_MOUNT}/data/{keys.CF_CRED_PATH}":
            return 200, {"data": {"data": {"api_token": "cf-token", "account_id": "a" * 32}}}
        if path == meta and method == "LIST":
            return (200, {"data": {"keys": sorted(self.vault)}}) if self.vault else (404, {})
        name = path.rsplit("/", 1)[1]
        if path.startswith(data + "/") and method == "POST":
            if self.fail_vault_write:
                return 403, {}
            e = self.vault.setdefault(name, {"version": 0, "custom": {}})
            e["data"], e["version"] = body["data"], e["version"] + 1
            return 200, {"data": {"version": e["version"]}}
        if path.startswith(meta + "/"):
            if method == "POST":
                self.vault[name]["custom"] = body["custom_metadata"]
                return 204, {}
            if method == "GET":
                e = self.vault.get(name)
                return (200, {"data": {"custom_metadata": e["custom"], "current_version": e["version"]}}) if e else (404, {})
            if method == "DELETE":
                self.vault.pop(name, None)
                return 204, {}
        return 500, {}

    def cf_call(self, method, url, body):
        tail = url.split("/service_tokens", 1)[1]
        if method == "GET":
            return 200, {"success": True, "result": list(self.cf.values()), "result_info": {"total_pages": 1}}
        if method == "POST" and tail == "":
            self.n += 1
            t = {"id": f"id{self.n}", "name": body["name"], "client_id": f"cid{self.n}.access",
                 "expires_at": "2027-02-07T00:00:00Z"}
            self.cf[t["id"]] = t
            return 200, {"success": True, "result": dict(t, client_secret=SECRET)}
        tid = tail.strip("/").split("/")[0]
        if method == "DELETE":
            self.cf.pop(tid, None)
            return 200, {"success": True, "result": {"id": tid}}
        if tail.endswith("/rotate"):
            self.rotate_bodies.append(body)
            return 200, {"success": True, "result": dict(self.cf[tid], client_secret="e" * 64)}
        if tail.endswith("/refresh"):
            return 200, {"success": True, "result": dict(self.cf[tid], expires_at="2027-03-01T00:00:00Z")}
        return 500, {"success": False}


def callers(*agents: str) -> str:
    body = "version: 1\npeople:\n  - name: pedro\n  - name: sonia\nagents:\n"
    for a in agents:
        body += f"  - name: {a}\n    owner: {'sonia' if a == 'batsy' else 'pedro'}\n"
    f = tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False)
    f.write(body)
    f.close()
    return f.name


def run(fake: Fake, path: str, argv: list[str]) -> tuple[int, str]:
    keys.CALLERS = path
    keys._request = fake
    out = io.StringIO()
    old = sys.argv
    sys.argv = ["keys.py", *argv]
    try:
        with contextlib.redirect_stdout(out):
            rc = keys.main()
    finally:
        sys.argv = old
    return rc, out.getvalue()


def digest(fake: Fake, path: str, rotate: str | None = None) -> str:
    rc, out = run(fake, path, ["plan"] + (["--rotate", rotate] if rotate else []))
    assert rc == 0, out
    return out.rsplit("plan-digest ", 1)[1].strip()


def main() -> int:
    os.environ.update(VAULT_ADDR="https://vault.test", VAULT_TOKEN="t")
    os.environ.pop("GITHUB_ACTIONS", None)
    os.environ.pop("GITHUB_OUTPUT", None)
    passed = 0

    # 1. create two agents
    fake, both = Fake(), callers("bobbert", "batsy")
    rc, out = run(fake, both, ["sync", "--expect", digest(fake, both)])
    assert rc == 0, out
    assert sorted(fake.vault) == ["batsy", "bobbert"], fake.vault
    hdr = fake.vault["batsy"]["data"]["header"]
    assert " " not in hdr and json.loads(hdr)["cf-access-client-secret"] == SECRET
    assert fake.vault["batsy"]["custom"]["owner"] == "sonia"
    assert SECRET not in out, "sync printed a secret"
    assert "created 2, revoked 0" in out, out
    passed += 1

    # 2. a second sync has nothing to do
    rc, out = run(fake, both, ["sync", "--expect", digest(fake, both)])
    assert rc == 0 and "created 0, revoked 0" in out, out
    passed += 1

    # 3. removing batsy revokes it in both places
    one = callers("bobbert")
    rc, out = run(fake, one, ["sync", "--expect", digest(fake, one)])
    assert rc == 0 and "revoked 1" in out, out
    assert list(fake.vault) == ["bobbert"] and len(fake.cf) == 1
    passed += 1

    # 4. a stale digest is refused and changes nothing
    stale = digest(fake, one)
    rc, out = run(fake, both, ["sync", "--expect", stale])
    assert rc == 1 and "plan changed" in out and "batsy" not in fake.vault, out
    passed += 1

    # 5. a failed Vault write deletes the new token
    bad = Fake(fail_vault_write=True)
    rc, out = run(bad, one, ["sync", "--expect", digest(bad, one)])
    assert rc == 1 and bad.cf == {}, (out, bad.cf)
    passed += 1

    # 6. rotate keeps a 24-hour overlap and writes the new secret
    rc, out = run(fake, one, ["rotate", "bobbert", "--expect", digest(fake, one, "bobbert")])
    assert rc == 0, out
    assert "previous_client_secret_expires_at" in fake.rotate_bodies[0]
    assert json.loads(fake.vault["bobbert"]["data"]["header"])["cf-access-client-secret"] == "e" * 64
    assert fake.vault["bobbert"]["custom"]["expires_at"] == "2027-03-01T00:00:00Z"
    assert "e" * 64 not in out
    passed += 1

    # 7. list reads metadata only and reports each agent
    rc, out = run(fake, one, ["list"])
    assert rc == 0 and "bobbert: owner pedro, version 2" in out, out
    passed += 1

    print(f"test-keys: {passed} of 7 cases passed")
    return 0 if passed == 7 else 1


if __name__ == "__main__":
    sys.exit(main())
