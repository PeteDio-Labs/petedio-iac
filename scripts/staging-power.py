#!/usr/bin/env python3
"""staging-power: start or stop the portfolio staging container (CT 249) on demand.

    scripts/staging-power.py auto|start|stop|status

Run by .github/workflows/staging-power.yml on the LAN runner, every 5 minutes (auto) or on a
dispatch with a forced mode. The container serves the portfolio's `staging` branch, so it should run
only while UI work is pending on that branch.

AUTO decides from GitHub, with the read-only staging App (kv/services/staging-app):
  pending  the `staging` branch differs from `main` outside .github. A squash-merge of staging into
           main ("send it") makes the content equal, so pending turns false and the box stops.
  recent   the newest commit on `staging` that the sync bot did not write is under IDLE_HOURS old.
  run when pending and recent, else stop. Only a change of state is sent to the node.

THE NODE SIDE. The job signs a 30-minute SSH certificate for the `staging-power` principal. That
role fixes the command to /usr/local/sbin/staging-power on pve03 (vault-config/staging-power.tf),
which accepts only `status`, `start` and `stop`, and acts only on CT 249.

THE LAST LINE SAYS WHAT WAS EXAMINED. A run that could not read GitHub or the node fails, and
stops nothing. A green run over a read that never happened is the bug this repo keeps shipping.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import pathlib
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
VAULT = os.environ.get("VAULT_ADDR", "https://192.168.50.223:8200").rstrip("/")
CA = os.environ.get("VAULT_CACERT", str(ROOT / "environments/homelab/vault-ca.crt"))
NODE = "192.168.50.10"  # pve03
NODE_KNOWN_HOSTS = os.environ.get("LAB_KNOWN_HOSTS", "/etc/ssh/lab-node-known-hosts")
SSH_ROLE = "staging-power"
REPO = "PeteDio-Labs/pdlabs-portfolio"
IDLE_HOURS = 3.0
SYNC_BOT = "github-actions[bot]"
SYNC_SUBJECT = "Merge main into staging"


class Abort(Exception):
    pass


# ── Decision (pure, tested offline) ───────────────────────────────────────────────────────────

PAGE = 100


def pending_from_files(files: list[dict]) -> bool:
    """True when the staging branch differs from main outside .github.

    The compare call returns one page of at most PAGE files. A full page that shows only .github
    files may hide more on the next page, so it counts as pending: the box stays up, which is the
    safe error."""
    if any(not f.get("filename", "").startswith(".github/") for f in files):
        return True
    return len(files) >= PAGE


def newest_ui_commit(commits: list[dict]) -> dict | None:
    """The newest commit the sync bot did not write. `commits` is newest first."""
    for c in commits:
        author = (c.get("author") or {}).get("login", "")
        subject = c.get("commit", {}).get("message", "").splitlines()[0] if c.get("commit") else ""
        if author == SYNC_BOT or subject.startswith(SYNC_SUBJECT):
            continue
        return c
    return None


def decide(pending: bool, last_ui_at: dt.datetime | None, now: dt.datetime, running: bool) -> tuple[str, str]:
    """(action, reason). action is start, stop or none."""
    recent = last_ui_at is not None and (now - last_ui_at) < dt.timedelta(hours=IDLE_HOURS)
    want = pending and recent
    if want and not running:
        return "start", "UI work is pending and the newest staging push is under %gh old" % IDLE_HOURS
    if not want and running:
        why = "nothing is pending on staging" if not pending else "no staging push for %gh or more" % IDLE_HOURS
        return "stop", why
    return "none", "container already %s" % ("running" if running else "stopped")


# ── Vault and the node ────────────────────────────────────────────────────────────────────────

def vault(method: str, path: str, body: dict | None = None) -> dict | None:
    token = os.environ.get("VAULT_TOKEN")
    if not token:
        raise Abort("VAULT_TOKEN is not set. Run this from staging-power.yml.")
    req = urllib.request.Request(
        f"{VAULT}/v1/{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"X-Vault-Token": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context(cafile=CA), timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None
        raise Abort(f"Vault answered {err.code} for {method} {path}: {err.read(300).decode(errors='replace')}")
    except (urllib.error.URLError, OSError) as err:
        raise Abort(f"cannot reach Vault for {method} {path}: {err}")


def node(word: str, workdir: pathlib.Path) -> str:
    """Run status, start or stop on the node. Returns the script's one-line answer."""
    assert word in ("status", "start", "stop")
    key = workdir / "key"
    if not key.exists():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", SSH_ROLE, "-f", str(key)], check=True)
        signed = vault("POST", f"ssh-client-signer/sign/{SSH_ROLE}", {"public_key": (workdir / "key.pub").read_text().strip()})
        if not signed:
            raise Abort(f"Vault has no SSH role {SSH_ROLE}. Apply vault-config first.")
        (workdir / "key-cert.pub").write_text(signed["data"]["signed_key"].strip() + "\n")
    proc = subprocess.run(
        ["ssh", "-i", str(key), "-o", f"CertificateFile={workdir / 'key-cert.pub'}", "-o", "IdentitiesOnly=yes",
         "-o", f"UserKnownHostsFile={NODE_KNOWN_HOSTS}", "-o", "StrictHostKeyChecking=yes",
         "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", f"root@{NODE}", word],
        capture_output=True, text=True, timeout=180,
    )
    if proc.returncode != 0:
        raise Abort(f"the node refused or failed '{word}' (exit {proc.returncode}): {(proc.stderr or proc.stdout).strip()[:300]}")
    out = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
    if not out.startswith("staging-249:"):
        raise Abort(f"the node answered '{word}' with an unexpected line: {out[:200]!r}")
    return out


# ── GitHub ────────────────────────────────────────────────────────────────────────────────────

def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def app_token(app_id: str, installation_id: str, pem: str, workdir: pathlib.Path) -> str:
    pem_file = workdir / "app.pem"
    pem_file.write_text(pem.strip() + "\n")
    os.chmod(pem_file, 0o600)
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iat": now - 30, "exp": now + 540, "iss": app_id}).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(pem_file)], input=f"{head}.{body}".encode(),
                         capture_output=True, check=True).stdout
    pem_file.unlink()
    jwt = f"{head}.{body}.{b64url(sig)}"
    out = github("POST", f"/app/installations/{installation_id}/access_tokens", jwt, "Bearer",
                 {"repositories": ["pdlabs-portfolio"], "permissions": {"contents": "read"}})
    token = (out or {}).get("token")
    if not token:
        raise Abort("GitHub's token reply held no token.")
    print(f"::add-mask::{token}")
    return token


def github(method: str, path: str, token: str, scheme: str = "token", body: dict | None = None):
    req = urllib.request.Request(
        "https://api.github.com" + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"{scheme} {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as err:
        raise Abort(f"GitHub answered {err.code} for {method} {path}: {err.read(200).decode(errors='replace')}")
    except (urllib.error.URLError, OSError) as err:
        raise Abort(f"cannot reach GitHub for {method} {path}: {err}")


def read_branch_state(token: str) -> tuple[bool, dt.datetime | None, str]:
    cmp_ = github("GET", f"/repos/{REPO}/compare/main...staging?per_page={PAGE}", token)
    pending = pending_from_files(cmp_.get("files", []))
    commits = github("GET", f"/repos/{REPO}/commits?sha=staging&per_page=30", token)
    ui = newest_ui_commit(commits)
    when = None
    sha = "none in the last 30"
    if ui:
        when = dt.datetime.fromisoformat(ui["commit"]["committer"]["date"].replace("Z", "+00:00"))
        sha = ui["sha"][:7]
    detail = f"compare main...staging: status {cmp_.get('status')}, {len(cmp_.get('files', []))} file(s); newest UI commit {sha}"
    return pending, when, detail


# ── Main ──────────────────────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in ("auto", "start", "stop", "status"):
        print(f"usage: {argv[0]} auto|start|stop|status", file=sys.stderr)
        return 2
    mode = argv[1]
    for tool in ("ssh", "ssh-keygen") + (("openssl",) if mode == "auto" else ()):
        if not shutil.which(tool):
            print(f"::error title=staging-power::{tool} is not installed on this runner.")
            return 1
    os.umask(0o077)
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="staging-power-", dir=os.environ.get("RUNNER_TEMP")))
    try:
        state = node("status", workdir)
        running = state.endswith("running")
        if mode == "status":
            print(f"staging-power status: examined the node only. {state}")
            return 0
        if mode in ("start", "stop"):
            if (mode == "start") == running:
                print(f"staging-power {mode}: examined the node only. {state}. Nothing to do.")
                return 0
            after = node(mode, workdir)
            print(f"staging-power {mode}: forced. before: {state}; after: {after}")
            return 0

        app = vault("GET", "kv/data/services/staging-app")
        if app is None:
            raise Abort("kv/services/staging-app is not seeded, so the staging branch cannot be read. The container was left as it is: " + state)
        data = app["data"]["data"]
        for k in ("app_id", "installation_id", "app_pem"):
            if not str(data.get(k, "")).strip():
                raise Abort(f"kv/services/staging-app lacks {k}.")
        token = app_token(str(data["app_id"]), str(data["installation_id"]), str(data["app_pem"]), workdir)
        pending, last_ui, detail = read_branch_state(token)
        now = dt.datetime.now(dt.timezone.utc)
        action, reason = decide(pending, last_ui, now, running)
        if action != "none":
            after = node(action, workdir)
        else:
            after = state
        print(f"staging-power auto: examined {detail}; pending={pending}; node before: {state}. "
              f"Decision: {action} ({reason}). Node after: {after}")
        return 0
    except Abort as err:
        print(f"::error title=staging-power::{err}")
        return 1
    except (subprocess.SubprocessError, OSError) as err:
        print(f"::error title=staging-power::{type(err).__name__}: {err}")
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
