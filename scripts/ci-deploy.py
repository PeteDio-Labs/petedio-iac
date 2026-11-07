#!/usr/bin/env python3
"""ci-deploy: run one host deploy from a deploy-<name>.yml workflow on the homelab runner.

    scripts/ci-deploy.py <name>      # name is a key of DEPLOYS below

Each deploy replaces a by-hand `scripts/deploy-*.sh`. The workflow has already logged in to Vault
through GitHub OIDC (VAULT_TOKEN) with a role that reads only this deploy's paths and signs only
this deploy's SSH role (vault-config/deploy-hosts.tf). This script then:

  1. reads the deploy's Vault records and masks every value in the log,
  2. stages them as an extra-vars JSON file, never as arguments,
  3. signs a fresh 30-minute SSH certificate for the deploy's own principal (the token is revoked
     in a `finally`, so an abort in step 1 or 2 does not leave it live),
  4. runs the playbook in Docker, after proving the play matches exactly the hosts it should,
  5. exits non-zero unless Ansible reports every expected host with failed=0 and unreachable=0.

THE LAST LINE SAYS WHAT WAS EXAMINED: the hosts the play matched, the hosts the recap reported,
changed, failed and unreachable. A deploy that matched no host, or whose recap named a different
host set, fails. A green tick over a play that reached nothing is the bug this repo keeps shipping.

Run only from a workflow_dispatch of main: the Vault role binds that. A caller outside a workflow
has no VAULT_TOKEN and stops at the first check.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
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
ANSIBLE_IMAGE = "python:3.12-slim"
ANSIBLE_CORE = "2.20.4"  # the version ansible-validate.yml lints against
NODE_KNOWN_HOSTS = "/etc/ssh/lab-node-known-hosts"  # pinned by lab-playbook.sh on each runner


class Abort(Exception):
    pass


# ── Vault ─────────────────────────────────────────────────────────────────────────────────────

def vault(method: str, path: str, body: dict | None = None) -> dict | None:
    """Call Vault. A 404 returns None. Any other failure aborts: an unread record must never read
    as an unseeded one."""
    token = os.environ.get("VAULT_TOKEN")
    if not token:
        raise Abort("VAULT_TOKEN is not set. Run this from a deploy-<name>.yml workflow.")
    req = urllib.request.Request(
        f"{VAULT}/v1/{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"X-Vault-Token": token, "Content-Type": "application/json"},
    )
    ctx = ssl.create_default_context(cafile=CA)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None
        raise Abort(f"Vault answered {err.code} for {method} {path}: {err.read(300).decode(errors='replace')}")
    except (urllib.error.URLError, OSError) as err:
        raise Abort(f"cannot reach Vault for {method} {path}: {err}")


_revoked = False


def revoke_token(name: str) -> None:
    """Revoke the run's Vault token once. A failed revoke leaves it to expire at its own TTL."""
    global _revoked
    if _revoked or not os.environ.get("VAULT_TOKEN"):
        return
    _revoked = True
    try:
        vault("POST", "auth/token/revoke-self")
    except Abort as err:
        print(f"::warning title=deploy-{name}::could not revoke the Vault token: {err}")


def mask(value: object) -> None:
    for line in str(value).splitlines():
        if line.strip():
            print(f"::add-mask::{line}")


def kv(path: str, required: bool) -> dict:
    """Read one record from the kv mount. Returns {} for an absent optional record, aborts for a required one."""
    out = vault("GET", "kv/data/" + path)
    if out is None:
        if required:
            raise Abort(f"kv/{path} does not exist. Seed it first (the seed script is named in the deploy's old script).")
        print(f"kv/{path}: not seeded (optional)")
        return {}
    data = out["data"]["data"]
    for value in data.values():
        mask(value)
    print(f"kv/{path}: read {len(data)} field(s)")
    return data


def need(record: dict, path: str, *fields: str) -> list[str]:
    missing = [f for f in fields if not str(record.get(f, "")).strip()]
    if missing:
        raise Abort(f"kv/{path} lacks {', '.join(missing)}.")
    return [str(record[f]) for f in fields]


# ── What each deploy stages ───────────────────────────────────────────────────────────────────

def stage_plane() -> dict:
    db = kv("db/plane", True)
    plane = kv("services/plane", True)
    claude = kv("services/plane-claude", True)
    members = {}
    # Keep this list equal to plane_mcp_members in configure-plane.yml and to host_deploys.plane.kv
    # in vault-config/deploy-hosts.tf. The play stops when a member's token is missing.
    for name in ("tom", "sonia"):
        members[name] = need(kv(f"services/plane-{name}", True), f"services/plane-{name}", "api_key")[0]
    return {
        "plane_db_password": need(db, "db/plane", "password")[0],
        "plane_secret_key": need(plane, "services/plane", "secret_key")[0],
        "plane_minio_access_key": need(plane, "services/plane", "access_key")[0],
        "plane_minio_secret_key": need(plane, "services/plane", "secret_key_minio")[0],
        "plane_live_secret_key": need(plane, "services/plane", "live_secret_key")[0],
        "plane_mq_password": need(plane, "services/plane", "mq_password")[0],
        "plane_mcp_api_key": need(claude, "services/plane-claude", "api_key")[0],
        "plane_mcp_member_keys": members,
    }


def stage_minio_data() -> dict:
    rec = kv("iac/minio-data-root", True)
    user, password = need(rec, "iac/minio-data-root", "root_user", "root_password")
    # No fallback and no placeholder: the role writes these into /etc/default/minio as the live
    # root account, so a blank or guessed value would stand up a MinIO nobody can sign in to.
    if len(password) < 8:
        raise Abort(f"root_password is shorter than the role's assert allows ({len(password)} chars).")
    return {"minio_root_user": user, "minio_root_password": password}


def discord(rec: dict) -> tuple[str, str]:
    token, channel = need(rec, "services/lab-watchdog", "discord_bot_token", "discord_dm_channel_id")
    if not channel.isdigit():
        raise Abort("kv/services/lab-watchdog holds a discord_dm_channel_id that is not a number.")
    return token, channel


def stage_metrics() -> dict:
    token, channel = discord(kv("services/lab-watchdog", True))
    return {"metric_alerts_discord_bot_token": token, "metric_alerts_discord_dm_channel_id": channel}


def stage_lab_watchdog() -> dict:
    token, channel = discord(kv("services/lab-watchdog", True))
    # The off-site heartbeat (PET-722) is optional: absent, the in-lab probe still runs and the
    # play leaves the heartbeat file as it is.
    aws = kv("services/aws-watchdog", False)
    return {
        "lab_watchdog_discord_bot_token": token,
        "lab_watchdog_discord_dm_channel_id": channel,
        "lab_watchdog_heartbeat_url": str(aws.get("heartbeat_url", "")),
        "lab_watchdog_heartbeat_secret": str(aws.get("heartbeat_secret", "")),
    }


def stage_codex() -> dict:
    app = kv("services/codex-review-app", False)
    plane = kv("services/codex-plane", False)
    bot = kv("services/pete-bot", False)
    app_id, inst, pem = (str(app.get(k, "")) for k in ("app_id", "installation_id", "app_pem"))
    # All three or none: a partial App identity mints nothing, and a half-written one is a seed bug.
    if app_id or inst or pem:
        if not (app_id and inst and pem):
            raise Abort("kv/services/codex-review-app is partial. Run scripts/seed-codex-review-app.sh again.")
        if not (app_id + inst).isdigit():
            raise Abort("kv/services/codex-review-app holds a non-numeric id.")
        if len(pem.strip().splitlines()) < 3:
            raise Abort("kv/services/codex-review-app app_pem lost its newlines. Re-seed it.")
    else:
        print("codex-review-app: not seeded, the play leaves the App identity on the host as it is")
    return {
        "codex_review_app_id": app_id,
        "codex_review_installation_id": inst,
        "codex_review_app_pem": pem,
        "codex_plane_api_key": str(plane.get("api_key", "")),
        "notify_pedro_token": str(bot.get("notify_bearer_token", "")),
    }


def stage_backup_store() -> dict:
    tokens = kv("services/backup-health", True)
    if not tokens:
        raise Abort("kv/services/backup-health holds no push tokens. Run scripts/seed-backup-health-vault.sh.")
    print("push tokens for: " + ", ".join(sorted(tokens)))
    return {"backup_store_health_push_tokens": tokens}


DEPLOYS = {
    "plane": {
        "playbook": "configure-plane.yml",
        "ssh_role": "deploy-plane",
        "hosts": {"plane-235"},
        "stage": stage_plane,
    },
    "minio-data": {
        "playbook": "configure-minio-data.yml",
        "ssh_role": "deploy-minio-data",
        "hosts": {"minio-data-245"},
        "stage": stage_minio_data,
    },
    "metrics": {
        "playbook": "configure-metrics.yml",
        "ssh_role": "deploy-metrics",
        "hosts": {"metrics-240"},
        "stage": stage_metrics,
    },
    "lab-watchdog": {
        "playbook": "configure-lab-watchdog.yml",
        "ssh_role": "deploy-lab-watchdog",
        "hosts": {"claude-247"},
        "stage": stage_lab_watchdog,
    },
    "codex-248": {
        "playbook": "configure-codex.yml",
        "ssh_role": "deploy-codex-248",
        "hosts": {"codex-248"},
        "stage": stage_codex,
    },
    # The nodes list the deploy-backup-store principal (group_vars, written by
    # configure-ssh-ca-deploy-hosts.yml). The node host keys are pinned on the runner, so it checks
    # them strictly.
    "backup-store": {
        "playbook": "configure-backup-store.yml",
        "ssh_role": "deploy-backup-store",
        "hosts": {"pve01", "pve02", "pve03"},
        "stage": stage_backup_store,
        "pinned_known_hosts": NODE_KNOWN_HOSTS,
    },
}


# ── SSH certificate ───────────────────────────────────────────────────────────────────────────

def sign_certificate(role: str, workdir: pathlib.Path) -> pathlib.Path:
    key = workdir / "key"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", role, "-f", str(key)], check=True)
    signed = vault("POST", f"ssh-client-signer/sign/{role}", {"public_key": (workdir / "key.pub").read_text().strip()})
    if not signed:
        raise Abort(f"Vault has no SSH role {role}. Apply vault-config first (deploy-hosts.tf).")
    cert = workdir / "key-cert.pub"
    cert.write_text(signed["data"]["signed_key"].strip() + "\n")
    described = subprocess.run(["ssh-keygen", "-L", "-f", str(cert)], check=True, capture_output=True, text=True).stdout
    if not re.search(rf"^\s*{re.escape(role)}$", described, re.M):
        raise Abort(f"the certificate does not name the {role} principal.")
    print("signed: " + next((ln.strip() for ln in described.splitlines() if "Valid:" in ln), "validity not shown"))
    # The token has done its work. Revoke it now, not after the play.
    revoke_token(role)
    return cert


# ── Ansible ───────────────────────────────────────────────────────────────────────────────────

def run_ansible(spec: dict, workdir: pathlib.Path) -> None:
    play = f"playbooks/{spec['playbook']}"
    pinned = spec.get("pinned_known_hosts")
    ssh_args = f"-o UserKnownHostsFile={pinned} -o StrictHostKeyChecking=yes" if pinned else ""
    mounts = [
        "-v", f"{ROOT / 'ansible'}:/ansible:ro",
        "-v", f"{ROOT / 'environments/homelab/vault-ca.crt'}:/environments/homelab/vault-ca.crt:ro",
        "-v", f"{workdir}:/ci:ro",
    ]
    if pinned:
        mounts += ["-v", f"{pinned}:{pinned}:ro"]
    # -i names the inventory directory. ansible-playbook exits 0 on a play that matches no host,
    # so the script below fails first unless the play lists hosts. The root user is explicit
    # because the inventory's user and key path do not exist in the container.
    script = (
        "apt-get update -q >/dev/null && apt-get install -y -q openssh-client >/dev/null && "
        f"pip install -q 'ansible-core=={ANSIBLE_CORE}' && "
        "ansible-galaxy collection install -q -r requirements.yml && "
        f"echo '--- targets ---' && ansible-playbook -i inventory/ {play} --list-hosts && echo '--- targets end ---' && "
        f"exec ansible-playbook -i inventory/ {play} -e @/ci/extra.json "
        "-e ansible_user=root -e ansible_ssh_private_key_file=/ci/key"
    )
    cmd = [
        "docker", "run", "--rm", "--network", "host", *mounts, "-w", "/ansible",
        "-e", f"ANSIBLE_HOST_KEY_CHECKING={'True' if pinned else 'False'}",
        "-e", "ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore",
        "-e", "ANSIBLE_NOCOLOR=1",
        *(["-e", f"ANSIBLE_SSH_ARGS={ssh_args}"] if ssh_args else []),
        ANSIBLE_IMAGE, "sh", "-c", script,
    ]
    lines: list[str] = []
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        lines.append(line.rstrip("\n"))
    rc = proc.wait()
    sys.stdout.flush()

    # The hosts the play listed, between the two markers.
    expected: set[str] = set()
    inside = False
    for line in lines:
        if line == "--- targets ---":
            inside = True
        elif line == "--- targets end ---":
            inside = False
        elif inside and re.match(r"^\s+[^\s:]+$", line):
            expected.add(line.strip())
    # PLAY RECAP lines: "<host> : ok=N changed=N unreachable=N failed=N ...".
    recap: dict[str, dict[str, int]] = {}
    in_recap = False
    for line in lines:
        if line.startswith("PLAY RECAP"):
            in_recap = True
        elif in_recap:
            m = re.match(r"^(\S+)\s+: (.*)$", line)
            if m:
                recap[m.group(1)] = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m.group(2))}
    changed = sum(r.get("changed", 0) for r in recap.values())
    failed = sum(r.get("failed", 0) for r in recap.values())
    unreachable = sum(r.get("unreachable", 0) for r in recap.values())
    want = spec["hosts"]
    print(
        f"deploy {spec['playbook']}: play matched {sorted(expected) or 'no hosts'}, recap reported "
        f"{sorted(recap) or 'no hosts'}, expected {sorted(want)}; changed={changed}, failed={failed}, "
        f"unreachable={unreachable} (ansible exit {rc})"
    )
    if rc != 0 or failed or unreachable:
        raise Abort("ansible did not finish clean.")
    if expected != want or set(recap) != want:
        raise Abort("the hosts the play matched or reported are not the hosts this deploy expects.")


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in DEPLOYS:
        print(f"usage: {argv[0]} <{'|'.join(DEPLOYS)}>", file=sys.stderr)
        return 2
    name = argv[1]
    spec = DEPLOYS[name]
    for tool in ("ssh-keygen", "docker"):
        if not shutil.which(tool):
            print(f"::error title=deploy-{name}::{tool} is not installed on this runner.")
            return 1
    os.umask(0o077)
    workdir = pathlib.Path(tempfile.mkdtemp(prefix=f"deploy-{name}-", dir=os.environ.get("RUNNER_TEMP")))
    try:
        print(f"deploy {name}: playbook {spec['playbook']}, ssh role {spec['ssh_role']}, sha {os.environ.get('GITHUB_SHA', 'local')[:7]}")
        extra = spec["stage"]()
        (workdir / "extra.json").write_text(json.dumps(extra))
        sign_certificate(spec["ssh_role"], workdir)
        run_ansible(spec, workdir)
    except Abort as err:
        print(f"::error title=deploy-{name}::{err}")
        return 1
    finally:
        # Revoke on every path, so an abort in staging does not leave the 900 s token live. The
        # signing step already revoked it on the success path.
        revoke_token(name)
        shutil.rmtree(workdir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
