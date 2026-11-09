#!/usr/bin/env python3
"""test-keys.py: drive scripts/keys.py against a fake Vault and a fake Cloudflare.

No network and no credentials. It proves the parts a live run cannot show safely:
  - sync creates a token per new agent, writes the one-line header to Vault, and prints no secret
  - a failed Vault write deletes the token it just created
  - sync revokes an agent removed from callers.yml, in Cloudflare and in Vault
  - sync refuses when the plan digest changed after approval
  - rotate keeps a 24-hour overlap, writes the new secret and never calls /refresh
  - sync refuses, changing nothing, when Cloudflare lost a token or holds a stray one
  - reissue repairs a lost token with a fresh 90 days
  - a revoke finishes when Cloudflare already deleted the token
  - an agent name with a trailing newline is refused
  - create reads expires_at back, since the create response need not carry it
  - renew keeps the token id and refuses unless Cloudflare reads back a 90-day expiry
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
import datetime as _dt
# A creation expiry well short of a renew, so a renew that changes nothing is visible.
CREATED = (_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
RENEWED = (_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ")


class Fake:
    def __init__(self, fail_vault_write: bool = False, renew_works: bool = True) -> None:
        self.renew_works = renew_works
        self.vault: dict[str, dict] = {}   # name -> {"data": ..., "custom": ..., "version": n}
        self.cf: dict[str, dict] = {}      # id -> token
        self.n = 0
        self.fail_vault_write = fail_vault_write
        self.rotate_bodies: list[dict] = []
        self.create_bodies: list[dict] = []
        self.refreshes = 0

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
        if method == "GET" and (tail == "" or tail.startswith("?")):
            return 200, {"success": True, "result": list(self.cf.values()), "result_info": {"total_pages": 1}}
        if method == "POST" and tail == "":
            self.create_bodies.append(body)
            self.n += 1
            t = {"id": f"id{self.n}", "name": body["name"], "client_id": f"cid{self.n}.access",
                 "expires_at": CREATED}
            self.cf[t["id"]] = t
            # The documented create response gives created_at and duration, not expires_at.
            out = {k: v for k, v in t.items() if k != "expires_at"}
            return 200, {"success": True, "result": dict(out, client_secret=SECRET, duration=body["duration"])}
        tid = tail.strip("/").split("/")[0]
        if method == "GET" and tid in self.cf:
            return 200, {"success": True, "result": dict(self.cf[tid])}
        if method == "PUT" and tid in self.cf:
            if self.renew_works:
                self.cf[tid]["expires_at"] = RENEWED
            return 200, {"success": True, "result": dict(self.cf[tid])}
        if method == "DELETE":
            if tid not in self.cf:
                return 404, {"success": False, "errors": [{"message": "not found"}]}
            self.cf.pop(tid)
            return 200, {"success": True, "result": {"id": tid}}
        if tail.endswith("/rotate"):
            self.rotate_bodies.append(body)
            return 200, {"success": True, "result": dict(self.cf[tid], client_secret="e" * 64)}
        if tail.endswith("/refresh"):
            self.refreshes += 1  # refresh extends by a year, so keys.py must never call it
            return 500, {"success": False}
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


def digest(fake: Fake, path: str, rotate: str | None = None, verb: str = "rotate") -> str:
    rc, out = run(fake, path, ["plan"] + ([f"--{verb}", rotate] if rotate else []))
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
    assert all(b["duration"] == "2160h" for b in fake.create_bodies), fake.create_bodies
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
    assert fake.vault["bobbert"]["custom"]["expires_at"] == CREATED
    assert fake.refreshes == 0, "rotate called /refresh"
    assert "e" * 64 not in out
    passed += 1

    # 7. list reads metadata only and reports each agent
    rc, out = run(fake, one, ["list"])
    assert rc == 0 and "bobbert: owner pedro, version 2" in out, out
    passed += 1

    # 8. a token deleted in the dashboard: sync refuses and changes nothing; reissue repairs it
    fake.cf.clear()
    before = json.dumps(fake.vault, sort_keys=True)
    rc, out = run(fake, one, ["sync", "--expect", digest(fake, one)])
    assert rc == 1 and "action=reissue name=bobbert" in out and "nothing changed" in out, out
    assert json.dumps(fake.vault, sort_keys=True) == before and fake.cf == {}
    rc, out = run(fake, one, ["reissue", "bobbert", "--expect", digest(fake, one, "bobbert", "reissue")])
    assert rc == 0 and "already absent" in out, out
    assert len(fake.cf) == 1 and fake.vault["bobbert"]["custom"]["token_id"] in fake.cf
    assert fake.create_bodies[-1]["duration"] == "2160h" and SECRET not in out
    passed += 1

    # 9. a stray agent-* token: sync refuses and leaves it for Pedro to judge
    fake.cf["stray"] = {"id": "stray", "name": "agent-ghost", "client_id": "x.access", "expires_at": ""}
    rc, out = run(fake, one, ["sync", "--expect", digest(fake, one)])
    assert rc == 1 and "agent-ghost" in out and "stray" in fake.cf, out
    fake.cf.pop("stray")
    passed += 1

    # 10. a revoke whose Cloudflare token is already gone still destroys the Vault entry
    fake2, two = Fake(), both
    run(fake2, two, ["sync", "--expect", digest(fake2, two)])
    gone = fake2.vault["batsy"]["custom"]["token_id"]
    fake2.cf.pop(gone)
    rc, out = run(fake2, one, ["sync", "--expect", digest(fake2, one)])
    assert rc == 0 and "revoked 1" in out and "already absent" in out, out
    assert "batsy" not in fake2.vault
    passed += 1

    # 11. a name with a trailing newline is refused
    rc, out = run(fake, one, ["plan", "--rotate", "bobbert\n"])
    assert rc == 1 and "REFUSED" in out, out
    passed += 1

    # 12. create stored the expiry it read back, not the empty one in the create response
    assert fake.vault["bobbert"]["custom"]["expires_at"] == CREATED, fake.vault["bobbert"]
    passed += 1

    # 13. renew keeps id, client id and secret, and records the new expiry
    before = dict(fake.vault["bobbert"])
    tid = before["custom"]["token_id"]
    rc, out = run(fake, one, ["renew", "bobbert", "--expect", digest(fake, one, "bobbert", "renew")])
    assert rc == 0, out
    after = fake.vault["bobbert"]
    assert after["custom"]["token_id"] == tid and after["custom"]["expires_at"] == RENEWED
    assert after["data"] == before["data"] and after["version"] == before["version"], "renew wrote a new secret"
    passed += 1

    # 14. renew refuses, changing nothing in Vault, when Cloudflare keeps the old expiry
    stuck, sone = Fake(renew_works=False), callers("bobbert")
    run(stuck, sone, ["sync", "--expect", digest(stuck, sone)])
    md = json.dumps(stuck.vault, sort_keys=True)
    rc, out = run(stuck, sone, ["renew", "bobbert", "--expect", digest(stuck, sone, "bobbert", "renew")])
    assert rc == 1 and "action=reissue" in out and json.dumps(stuck.vault, sort_keys=True) == md, out
    passed += 1

    # 15. the reissue plan names what a new token id breaks
    rc, out = run(fake, one, ["plan", "--reissue", "bobbert"])
    assert rc == 0 and "Terraform apply" in out and "client id" in out, out
    passed += 1

    print(f"test-keys: {passed} of 15 cases passed")
    return 0 if passed == 15 else 1


if __name__ == "__main__":
    sys.exit(main())
