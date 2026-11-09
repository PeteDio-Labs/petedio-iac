#!/usr/bin/env python3
"""keys.py: make Cloudflare Access service tokens and Vault match secrets/callers.yml.

Each agent in secrets/callers.yml gets one Cloudflare Access service token, named
`agent-<name>`. The token's one-header value lives in Vault at kv/callers/edge/<name>, field
`header`, and the agent's owner copies it from there into the agent's own credential store.
A route lets an agent through when its `agents` list names it (modules/cloudflare-ingress).

Commands:
  check              offline: validate callers.yml and every `agents = [...]` list in
                     environments/homelab. No credentials. Runs on every pull request.
  self-test          prove that check fails on a bad callers file.
  plan               read Vault metadata and print what sync would create and revoke, with a
                     digest. Needs VAULT_ADDR and VAULT_TOKEN (the keys-list role).
  list               read Vault metadata and print each agent's owner, version and expiry.
  sync --expect D    create a token for each agent that has none and revoke each token whose
                     agent left callers.yml. Refuses unless the plan digest still equals D,
                     and refuses before any change when Cloudflare disagrees with Vault.
                     Needs the keys-sync role, which reads the Cloudflare token.
  rotate NAME --expect D
                     replace NAME's secret and keep the old one valid for 24 hours. The
                     token's expiry does not change.
  renew NAME --expect D
                     set NAME's token to 90 days from now. The token id, client id and secret
                     stay, so routes and doors need no change. Refuses unless Cloudflare reads
                     back the new expiry.
  reissue NAME --expect D
                     delete NAME's token and create another. Only for a token Cloudflare lost,
                     or when renew refuses. The token id and client id change, so each route
                     that lists NAME needs a Terraform apply, and each door its client id.

What it never does: print a secret, write one to a file, or put one in argv. Inside GitHub
Actions it registers each new secret with ::add-mask:: before anything else can print it. A
Cloudflare error prints the status and the error messages only, never the response body,
because a create or rotate response carries the secret.

Every command ends with a line that says what it examined, and exits 2 when it examined nothing,
so "0 problems" cannot hide "0 read" (the PET-298 shape).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CALLERS = os.environ.get("KEYS_CALLERS") or os.path.join(REPO_ROOT, "secrets", "callers.yml")
ROUTE_GLOB = os.path.join(REPO_ROOT, "environments", "homelab", "*.tf")

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")
TOKEN_PREFIX = "agent-"
VAULT_MOUNT = "kv"
VAULT_PREFIX = "callers/edge"
CF_CRED_PATH = "services/keys-cloudflare"
CF_API = "https://api.cloudflare.com/client/v4"
# 90 days (Pedro, 2026-11-09). The register's nightly check warns 21 days ahead.
TOKEN_DURATION = "2160h"
ROTATE_OVERLAP = dt.timedelta(hours=24)
# A renew must leave at least this long; a 90-day renew leaves 90 days, less clock skew.
RENEW_FLOOR = dt.timedelta(days=89)
EXPIRY_WARN = dt.timedelta(days=21)
# `agents = ["bobbert", "batsy"]` on a route. Matches one line, as terraform fmt writes it.
AGENTS_LIST = re.compile(r'^\s*agents\s*=\s*\[([^\]]*)\]', re.M)
# mtrace's write callers live in the deploy play. callers.yml records each agent's mtrace scope
# too, so a reader sees it in one place; check() fails when the two disagree.
MTRACE_PLAY = os.path.join(REPO_ROOT, "ansible", "playbooks", "configure-media-dash.yml")
MTRACE_WRITERS = re.compile(r'^\s*mtrace_write_callers:\s*\[([^\]]*)\]', re.M)


class Fail(Exception):
    """A refusal: the message says what was refused and why. Exit 1."""


# ---------------------------------------------------------------------------------- callers file

def load_callers(path: str) -> dict:
    try:
        import yaml
    except ImportError:  # fail closed: a checker that cannot read its input checks nothing
        print("keys: PyYAML is not installed, so nothing was examined.", file=sys.stderr)
        sys.exit(2)
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise Fail(f"{path} is not a mapping")
    return data


def validate(data: dict) -> tuple[list[str], dict[str, dict]]:
    """Return (problems, agents by name)."""
    problems: list[str] = []
    if data.get("version") != 1:
        problems.append("version must be 1")
    people = data.get("people") or []
    agents = data.get("agents") or []
    if not isinstance(people, list) or not isinstance(agents, list):
        return ["people and agents must be lists"], {}
    known = set()
    for p in people:
        n = (p or {}).get("name") if isinstance(p, dict) else None
        if not isinstance(n, str) or not NAME_RE.fullmatch(n):
            problems.append(f"person {p!r}: name must match {NAME_RE.pattern}")
            continue
        if n in known:
            problems.append(f"person {n}: listed twice")
        known.add(n)
    by_name: dict[str, dict] = {}
    for a in agents:
        if not isinstance(a, dict):
            problems.append(f"agent {a!r}: must be a mapping")
            continue
        n, owner = a.get("name"), a.get("owner")
        extra = set(a) - {"name", "owner", "note", "mtrace"}
        if a.get("mtrace", "read") not in ("read", "write"):
            problems.append(f"agent {n}: mtrace must be read or write")
        if extra:
            problems.append(f"agent {n}: unknown field(s) {sorted(extra)}")
        if not isinstance(n, str) or not NAME_RE.fullmatch(n):
            problems.append(f"agent {n!r}: name must match {NAME_RE.pattern}")
            continue
        if n in by_name:
            problems.append(f"agent {n}: listed twice")
        if n in known:
            problems.append(f"agent {n}: has the same name as a person")
        if owner not in known:
            problems.append(f"agent {n}: owner {owner!r} is not in people")
        by_name[n] = a
    return problems, by_name


def route_agents() -> tuple[dict[str, list[str]], int]:
    """Return ({file: [agent names]}, files read) for every `agents = [...]` in the env."""
    found: dict[str, list[str]] = {}
    files = sorted(glob.glob(ROUTE_GLOB))
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for m in AGENTS_LIST.finditer(text):
            names = re.findall(r'"([^"]*)"', m.group(1))
            found.setdefault(os.path.relpath(path, REPO_ROOT), []).extend(names)
    return found, len(files)


def mtrace_writers() -> list[str] | None:
    try:
        with open(MTRACE_PLAY, encoding="utf-8") as f:
            m = MTRACE_WRITERS.search(f.read())
    except OSError:
        return None
    return re.findall(r'"([^"]*)"', m.group(1)) if m else None


def cmd_check(path: str) -> int:
    data = load_callers(path)
    problems, agents = validate(data)
    refs, files = route_agents()
    nrefs = 0
    for f, names in refs.items():
        for n in names:
            nrefs += 1
            if n not in agents:
                problems.append(f"{f}: route lists agent {n!r}, which is not in callers.yml")
    writers = mtrace_writers()
    if writers is None:
        problems.append(f"{os.path.relpath(MTRACE_PLAY, REPO_ROOT)}: no mtrace_write_callers list found")
    else:
        for n, a in agents.items():
            want = a.get("mtrace", "read") == "write"
            if want != (n in writers):
                live = "write" if n in writers else "read"
                problems.append(f"agent {n}: callers.yml says mtrace {a.get('mtrace', 'read')}, "
                                f"but mtrace_write_callers makes it {live}")
    for p in problems:
        print(f"FAIL {p}")
    people = len(data.get("people") or [])
    print(f"keys check: read {len(agents)} agents and {people} people in {os.path.relpath(path, REPO_ROOT)}, "
          f"{nrefs} route agent references in {files} files; {len(problems)} problems")
    if files == 0:
        print("keys check: no Terraform files were read, so nothing was examined.", file=sys.stderr)
        return 2
    return 1 if problems else 0


def cmd_self_test() -> int:
    bad = (
        "version: 1\npeople:\n  - name: pedro\nagents:\n"
        "  - name: Bad_Name\n    owner: pedro\n"
        "  - name: orphan\n    owner: nobody\n"
        "  - name: twice\n    owner: pedro\n  - name: twice\n    owner: pedro\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as f:
        f.write(bad)
        tmp = f.name
    try:
        problems, _ = validate(load_callers(tmp))
    finally:
        os.unlink(tmp)
    want = ["name must match", "owner 'nobody'", "listed twice"]
    missing = [w for w in want if not any(w in p for p in problems)]
    if missing:
        print(f"keys self-test: FAILED, check did not catch {missing}")
        return 1
    print(f"keys self-test: a bad callers file produced {len(problems)} problems, as expected")
    return 0


# ---------------------------------------------------------------------------------------- HTTP

def _ctx(cafile: str | None) -> ssl.SSLContext:
    return ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()


def _request(method: str, url: str, headers: dict, body: dict | None, ctx) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except ValueError:
            return e.code, {}


class Vault:
    def __init__(self) -> None:
        self.addr = os.environ.get("VAULT_ADDR", "").rstrip("/")
        self.token = os.environ.get("VAULT_TOKEN", "")
        if not self.addr or not self.token:
            raise Fail("VAULT_ADDR and VAULT_TOKEN must be set")
        self.ctx = _ctx(os.environ.get("VAULT_CACERT"))

    def _call(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        return _request(method, f"{self.addr}/v1/{path}", {"X-Vault-Token": self.token}, body, self.ctx)

    def list_agents(self) -> list[str]:
        code, j = self._call("LIST", f"{VAULT_MOUNT}/metadata/{VAULT_PREFIX}")
        if code == 404:
            return []  # Vault answers 404 to a LIST of an empty prefix
        if code != 200:
            raise Fail(f"Vault LIST {VAULT_MOUNT}/metadata/{VAULT_PREFIX} returned {code}")
        return sorted(k for k in j.get("data", {}).get("keys", []) if not k.endswith("/"))

    def metadata(self, name: str) -> dict:
        code, j = self._call("GET", f"{VAULT_MOUNT}/metadata/{VAULT_PREFIX}/{name}")
        if code != 200:
            raise Fail(f"Vault metadata read for {name} returned {code}")
        return j.get("data", {})

    def write(self, name: str, data: dict, custom: dict) -> int:
        code, j = self._call("POST", f"{VAULT_MOUNT}/data/{VAULT_PREFIX}/{name}", {"data": data})
        if code not in (200, 204):
            raise Fail(f"Vault write for {name} returned {code}")
        version = j.get("data", {}).get("version", 0)
        code, _ = self._call("POST", f"{VAULT_MOUNT}/metadata/{VAULT_PREFIX}/{name}", {"custom_metadata": custom})
        if code not in (200, 204):
            raise Fail(f"Vault metadata write for {name} returned {code}")
        return version

    def set_custom(self, name: str, custom: dict) -> None:
        code, _ = self._call("POST", f"{VAULT_MOUNT}/metadata/{VAULT_PREFIX}/{name}", {"custom_metadata": custom})
        if code not in (200, 204):
            raise Fail(f"Vault metadata write for {name} returned {code}")

    def destroy(self, name: str) -> None:
        code, _ = self._call("DELETE", f"{VAULT_MOUNT}/metadata/{VAULT_PREFIX}/{name}")
        if code not in (200, 204):
            raise Fail(f"Vault delete for {name} returned {code}")

    def cf_credentials(self) -> tuple[str, str]:
        code, j = self._call("GET", f"{VAULT_MOUNT}/data/{CF_CRED_PATH}")
        if code != 200:
            raise Fail(f"Vault read of kv/{CF_CRED_PATH} returned {code}. Run scripts/seed-keys-cloudflare.sh.")
        d = j.get("data", {}).get("data", {})
        token, account = d.get("api_token", ""), d.get("account_id", "")
        if not token or not re.fullmatch(r"[0-9a-f]{32}", account):
            raise Fail(f"kv/{CF_CRED_PATH} lacks api_token or a 32-hex account_id")
        return token, account


class Cloudflare:
    def __init__(self, token: str, account: str) -> None:
        self.base = f"{CF_API}/accounts/{account}/access/service_tokens"
        self.headers = {"Authorization": f"Bearer {token}"}
        self.ctx = _ctx(None)

    def _call(self, method: str, suffix: str = "", body: dict | None = None, what: str = "",
              missing_ok: bool = False) -> dict | None:
        code, j = _request(method, self.base + suffix, self.headers, body, self.ctx)
        if missing_ok and code == 404:
            return None
        if code >= 300 or not j.get("success", False):
            msgs = "; ".join(str(e.get("message", "")) for e in j.get("errors", []) if isinstance(e, dict))
            raise Fail(f"Cloudflare {what or method} returned {code}: {msgs or 'no error message'}")
        return j.get("result") or {}

    def list_agent_tokens(self) -> dict[str, dict]:
        out: dict[str, dict] = {}
        page = 1
        while True:
            code, j = _request("GET", f"{self.base}?per_page=100&page={page}", self.headers, None, self.ctx)
            if code != 200 or not j.get("success", False):
                raise Fail(f"Cloudflare list service tokens returned {code}")
            for t in j.get("result") or []:
                if t.get("name", "").startswith(TOKEN_PREFIX):
                    out[t["name"][len(TOKEN_PREFIX):]] = t
            info = j.get("result_info") or {}
            if page >= int(info.get("total_pages") or 1):
                return out
            page += 1

    def create(self, name: str) -> dict:
        return self._call("POST", body={"name": TOKEN_PREFIX + name, "duration": TOKEN_DURATION}, what=f"create {name}")

    def rotate(self, token_id: str, name: str) -> dict:
        until = (dt.datetime.now(dt.timezone.utc) + ROTATE_OVERLAP).strftime("%Y-%m-%dT%H:%M:%SZ")
        return self._call("POST", f"/{token_id}/rotate", {"previous_client_secret_expires_at": until}, f"rotate {name}")

    # No refresh(): Cloudflare's refresh extends a token by one year, not by its own 90 days
    # (Codex review of petedio-iac#685). To renew, reissue.

    def get(self, token_id: str, name: str) -> dict:
        return self._call("GET", f"/{token_id}", what=f"read {name}") or {}

    def renew(self, token_id: str, name: str) -> dict:
        return self._call("PUT", f"/{token_id}", {"name": TOKEN_PREFIX + name, "duration": TOKEN_DURATION},
                          f"renew {name}") or {}

    def delete(self, token_id: str, name: str) -> bool:
        """Delete a token. Returns False when Cloudflare no longer has it, so a retry can finish."""
        return self._call("DELETE", f"/{token_id}", what=f"delete {name}", missing_ok=True) is not None


def mask(*values: str) -> None:
    """Register secrets with the Actions log masker before anything else can print them."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for v in values:
            if v:
                print(f"::add-mask::{v}", flush=True)


def header_value(client_id: str, client_secret: str) -> str:
    # One line, no spaces: Muse sends the stored string as the header value (2026-11-09).
    return json.dumps({"cf-access-client-id": client_id, "cf-access-client-secret": client_secret},
                      separators=(",", ":"))


def parse_time(value: str) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def expiry_of_new(cf: "Cloudflare", t: dict, name: str) -> str:
    """Cloudflare's create response need not carry expires_at, so read the token back."""
    exp = t.get("expires_at") or cf.get(t["id"], name).get("expires_at") or ""
    if parse_time(exp) is None:
        print(f"sync: WARNING Cloudflare gave no expires_at for {TOKEN_PREFIX}{name}; "
              "the register check reports its expiry as unknown")
        return ""
    return exp


# ------------------------------------------------------------------------------------- plan/sync

def compute_plan(agents: dict[str, dict], in_vault: list[str], target: str | None = None,
                 verb: str = "rotate") -> tuple[list[str], str]:
    if target:
        if verb not in ("rotate", "renew", "reissue"):
            raise Fail(f"unknown action {verb}")
        if not NAME_RE.fullmatch(target):
            raise Fail("the agent name must match ^[a-z][a-z0-9-]{1,30}$")
        if target not in agents:
            raise Fail(f"{target} is not in callers.yml")
        if target not in in_vault:
            raise Fail(f"{target} has no token yet. Run sync first.")
        actions = [f"{verb} {target}"]
    else:
        actions = [f"create {n}" for n in sorted(set(agents) - set(in_vault))]
        actions += [f"revoke {n}" for n in sorted(set(in_vault) - set(agents))]
    digest = hashlib.sha256("\n".join(actions).encode()).hexdigest()[:16]
    return actions, digest


def cmd_plan(target: str | None, verb: str) -> int:
    _, agents = _valid_agents()
    vault = Vault()
    in_vault = vault.list_agents()
    actions, digest = compute_plan(agents, in_vault, target, verb)
    for a in actions:
        print(f"plan: {a}")
    if any(a.startswith("create ") for a in actions):
        print("plan: each create first deletes an agent-<name> token that has no Vault entry, "
              "since nobody holds its secret")
    if not target:
        print("plan: apply refuses, and changes nothing, if Cloudflare disagrees with Vault")
    if verb == "reissue" and target:
        routes = [f for f, names in route_agents()[0].items() if target in names]
        print(f"plan: reissue changes {target}'s token id and client id. Until a Terraform apply, "
              f"routes that list {target} refuse it, in {len(routes)} files: {', '.join(routes) or 'none'}. "
              f"Each door that maps {target} needs the client id from action=list.")
    print(f"keys plan: read {len(agents)} agents in callers.yml and {len(in_vault)} Vault entries; "
          f"{len(actions)} actions; plan-digest {digest}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"digest={digest}\nactions={len(actions)}\n")
    return 0


def cmd_list() -> int:
    _, agents = _valid_agents()
    vault = Vault()
    in_vault = vault.list_agents()
    now = dt.datetime.now(dt.timezone.utc)
    expired = 0
    for n in sorted(set(agents) | set(in_vault)):
        if n not in in_vault:
            print(f"{n}: no token (sync creates it)")
            continue
        md = vault.metadata(n)
        cm = md.get("custom_metadata") or {}
        exp = cm.get("expires_at", "")
        left = ""
        try:
            when = dt.datetime.fromisoformat(exp.replace("Z", "+00:00"))
            days = (when - now).days
            left = f", {days} days left"
            if when <= now:
                expired += 1
                left = ", EXPIRED"
            elif when - now <= EXPIRY_WARN:
                left += " (renew soon)"
        except ValueError:
            left = ", expiry unknown"
        state = "in callers.yml" if n in agents else "NOT in callers.yml (sync revokes it)"
        # The client id is not secret: a door maps it to the caller name.
        print(f"{n}: owner {cm.get('owner', '?')}, version {md.get('current_version', '?')}, "
              f"client id {cm.get('client_id', '?')}, expires {exp or '?'}{left}; {state}")
    print(f"keys list: read {len(agents)} agents in callers.yml and {len(in_vault)} Vault entries; {expired} expired")
    return 1 if expired else 0


def _valid_agents() -> tuple[dict, dict[str, dict]]:
    data = load_callers(CALLERS)
    problems, agents = validate(data)
    if problems:
        raise Fail("callers.yml is invalid: " + "; ".join(problems))
    return data, agents


def cmd_sync(expect: str) -> int:
    _, agents = _valid_agents()
    vault = Vault()
    in_vault = vault.list_agents()
    actions, digest = compute_plan(agents, in_vault, None)
    if digest != expect:
        raise Fail(f"the plan changed since it was approved (digest {digest}, approved {expect}). Run sync again.")
    cf = Cloudflare(*vault.cf_credentials())
    tokens = cf.list_agent_tokens()
    ids = {t.get("id") for t in tokens.values()}
    # Reconcile both stores before any change. The plan reads Vault only, so anything that
    # Cloudflare alone reveals was not approved: say what it is and change nothing.
    drift = []
    for name in sorted(set(agents) & set(in_vault)):
        token_id = (vault.metadata(name).get("custom_metadata") or {}).get("token_id")
        if not token_id or token_id not in ids:
            drift.append(f"{name}: Vault holds a token Cloudflare does not have. "
                         f"Dispatch keys.yml action=reissue name={name}.")
    for name in sorted(set(tokens) - set(agents) - set(in_vault)):
        drift.append(f"{TOKEN_PREFIX}{name}: a Cloudflare token that callers.yml and Vault do not know. "
                     "Delete it under Access > Service credentials, or add the agent to callers.yml.")
    if drift:
        for d in drift:
            print(f"sync: drift: {d}")
        raise Fail(f"{len(drift)} drift findings after reading {len(agents)} agents, {len(in_vault)} Vault entries "
                   f"and {len(tokens)} Cloudflare agent tokens; nothing changed")
    created = revoked = 0
    for a in actions:
        verb, name = a.split(" ", 1)
        if verb == "create":
            if name in tokens:
                # A token with no Vault entry: an earlier run created it and failed before the
                # write. Nobody holds its secret, so replacing it loses nothing.
                cf.delete(tokens[name]["id"], name)
                print(f"sync: deleted {TOKEN_PREFIX}{name}, which had no Vault entry")
            t = cf.create(name)
            mask(t.get("client_secret", ""), header_value(t.get("client_id", ""), t.get("client_secret", "")))
            if not t.get("client_secret") or not t.get("id"):
                raise Fail(f"Cloudflare create {name} returned no secret or id")
            try:
                expires = expiry_of_new(cf, t, name)
                version = vault.write(name, {"header": header_value(t["client_id"], t["client_secret"]),
                                             "client_id": t["client_id"]},
                                      {"owner": agents[name]["owner"], "token_id": t["id"],
                                       "client_id": t["client_id"], "expires_at": expires})
            except Fail:
                cf.delete(t["id"], name)  # never leave a token whose secret nobody holds
                raise
            created += 1
            print(f"sync: created {TOKEN_PREFIX}{name} for owner {agents[name]['owner']}, "
                  f"Vault version {version}, expires {expires or 'unknown'}")
        else:
            md = vault.metadata(name)
            want = {(md.get("custom_metadata") or {}).get("token_id"), (tokens.get(name) or {}).get("id")} - {None, ""}
            # A token Cloudflare no longer has counts as deleted, so a retry after a failed
            # Vault delete finishes the revoke instead of failing on Cloudflare's 404.
            deleted = sum(cf.delete(tid, name) for tid in sorted(want))
            vault.destroy(name)
            revoked += 1
            print(f"sync: revoked {TOKEN_PREFIX}{name}; Cloudflare token "
                  f"{'deleted' if deleted else 'was already absent'}, Vault entry destroyed")
    print(f"keys sync: read {len(agents)} agents, {len(in_vault)} Vault entries, {len(tokens)} Cloudflare agent tokens; "
          f"created {created}, revoked {revoked}, kept {len(agents) - created}")
    return 0


def _approved(name: str, verb: str, expect: str) -> tuple[dict, "Vault", dict, "Cloudflare", dict]:
    _, agents = _valid_agents()
    vault = Vault()
    in_vault = vault.list_agents()
    _, digest = compute_plan(agents, in_vault, name, verb)
    if digest != expect:
        raise Fail(f"the plan changed since it was approved (digest {digest}, approved {expect})")
    cm = vault.metadata(name).get("custom_metadata") or {}
    cf = Cloudflare(*vault.cf_credentials())
    return agents, vault, cm, cf, cf.list_agent_tokens()


def cmd_rotate(name: str, expect: str) -> int:
    agents, vault, cm, cf, tokens = _approved(name, "rotate", expect)
    token_id, client_id = cm.get("token_id"), cm.get("client_id")
    if not token_id or not client_id:
        raise Fail(f"Vault metadata for {name} lacks token_id or client_id. Dispatch action=reissue.")
    live = next((t for t in tokens.values() if t.get("id") == token_id), None)
    if live is None:
        raise Fail(f"Cloudflare has no token {token_id} for {name}. Dispatch action=reissue name={name}.")
    t = cf.rotate(token_id, name)
    secret = t.get("client_secret", "")
    client_id = t.get("client_id") or client_id
    mask(secret, header_value(client_id, secret))
    if not secret:
        raise Fail(f"Cloudflare rotate {name} returned no secret. The old one stays valid for 24 hours; run rotate again.")
    # Rotating replaces the secret only; the token keeps its expiry.
    expires = t.get("expires_at") or live.get("expires_at") or cm.get("expires_at", "")
    try:
        version = vault.write(name, {"header": header_value(client_id, secret), "client_id": client_id},
                              {"owner": agents[name]["owner"], "token_id": token_id, "client_id": client_id,
                               "expires_at": expires})
    except Fail as e:
        raise Fail(f"{e}. Cloudflare rotated {name}, so the old secret stops working in 24 hours; run rotate again.")
    print(f"keys rotate: {TOKEN_PREFIX}{name} rotated, Vault version {version}, expires {expires}; "
          f"the old secret works until {ROTATE_OVERLAP} from now. Tell {agents[name]['owner']} to update the agent.")
    return 0


def cmd_reissue(name: str, expect: str) -> int:
    agents, vault, cm, cf, tokens = _approved(name, "reissue", expect)
    old = {cm.get("token_id"), (tokens.get(name) or {}).get("id")} - {None, ""}
    deleted = sum(cf.delete(tid, name) for tid in sorted(old))
    t = cf.create(name)
    mask(t.get("client_secret", ""), header_value(t.get("client_id", ""), t.get("client_secret", "")))
    if not t.get("client_secret") or not t.get("id"):
        raise Fail(f"Cloudflare create {name} returned no secret or id. Dispatch reissue again.")
    try:
        expires = expiry_of_new(cf, t, name)
        version = vault.write(name, {"header": header_value(t["client_id"], t["client_secret"]),
                                     "client_id": t["client_id"]},
                              {"owner": agents[name]["owner"], "token_id": t["id"],
                               "client_id": t["client_id"], "expires_at": expires})
    except Fail:
        cf.delete(t["id"], name)  # never leave a token whose secret nobody holds
        raise
    print(f"keys reissue: {TOKEN_PREFIX}{name} reissued, old token {'deleted' if deleted else 'was already absent'}, "
          f"Vault version {version}, expires {expires or 'unknown'}, new client id {t['client_id']}. "
          f"The old secret no longer works; tell {agents[name]['owner']} to update the agent. Every route "
          f"that lists {name} refuses it until a Terraform apply, and every door needs the new client id.")
    return 0


def cmd_renew(name: str, expect: str) -> int:
    agents, vault, cm, cf, tokens = _approved(name, "renew", expect)
    token_id = cm.get("token_id")
    if not token_id or not any(t.get("id") == token_id for t in tokens.values()):
        raise Fail(f"Cloudflare has no token {token_id or '?'} for {name}. Dispatch action=reissue name={name}.")
    floor = dt.datetime.now(dt.timezone.utc) + RENEW_FLOOR
    cf.renew(token_id, name)
    # Read back rather than trust the update's answer: renew counts only if Cloudflare now
    # reports an expiry at least RENEW_FLOOR ahead.
    expires = cf.get(token_id, name).get("expires_at") or ""
    when = parse_time(expires)
    if when is None or when < floor:
        raise Fail(f"Cloudflare kept {TOKEN_PREFIX}{name}'s expiry at {expires or 'unknown'} after the update. "
                   f"Nothing else changed. Dispatch action=reissue name={name} to get a fresh 90 days.")
    vault.set_custom(name, dict(cm, expires_at=expires))
    print(f"keys renew: {TOKEN_PREFIX}{name} now expires {expires}; token id, client id and secret unchanged. "
          f"read 1 Vault entry and {len(tokens)} Cloudflare agent tokens")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    sub.add_parser("self-test")
    p = sub.add_parser("plan")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--rotate", metavar="NAME")
    g.add_argument("--renew", metavar="NAME")
    g.add_argument("--reissue", metavar="NAME")
    sub.add_parser("list")
    s = sub.add_parser("sync")
    s.add_argument("--expect", required=True)
    for verb in ("rotate", "renew", "reissue"):
        r = sub.add_parser(verb)
        r.add_argument("name")
        r.add_argument("--expect", required=True)
    a = ap.parse_args()
    try:
        if a.cmd == "check":
            return cmd_check(CALLERS)
        if a.cmd == "self-test":
            return cmd_self_test()
        if a.cmd == "plan":
            if a.reissue:
                return cmd_plan(a.reissue, "reissue")
            if a.renew:
                return cmd_plan(a.renew, "renew")
            return cmd_plan(a.rotate, "rotate")
        if a.cmd == "list":
            return cmd_list()
        if a.cmd == "sync":
            return cmd_sync(a.expect)
        if a.cmd == "reissue":
            return cmd_reissue(a.name, a.expect)
        if a.cmd == "renew":
            return cmd_renew(a.name, a.expect)
        return cmd_rotate(a.name, a.expect)
    except Fail as e:
        print(f"keys {a.cmd}: REFUSED: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
