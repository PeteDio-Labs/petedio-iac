# Runbook — (re)provision a self-hosted GitHub Actions runner (runner-232 / runner-233)

This runbook brings a runner LXC from a bare container to a **registered, Docker-capable,
green** self-hosted runner — entirely from IaC. Linear: **PET-80** (the registration half;
`runner.tf` already owns the LXC, `configure-runner-docker.yml` the Docker half, both now
folded into `configure-runner.yml`).

Two org-scoped runners exist (`runner.tf`): **runner-232** (LXC 232, pve01) and
**runner-233** (LXC 233, pve02). Both register to the **PeteDio-Labs org** with labels
`self-hosted,linux,x64,homelab`.

> [!CAUTION]
> This box can reach the whole `192.168.50.0/24` and is CI's path to Vault — see the
> PET-104 note in `runner.tf`. PR-controlled code must never run on it; that gate lives in
> `.github/workflows/terraform.yml` + the `github-actions` Vault role, not here.

---

## When to use this

- A runner LXC was lost / rebuilt and CI has no runner (jobs queue with "no runner online"), **or**
- you're standing up an additional runner.

For a routine change (Docker bump, re-register with new labels) just re-run the play
(idempotent) — you do **not** need a from-scratch rebuild.

---

## One-time prerequisite (operator) — seed the org-runner PAT in Vault

The play mints a short-lived org **registration token** at runtime, which needs a
credential that can manage the org's self-hosted runners. Create it once:

1. Mint a **fine-grained PAT** (or a GitHub App token) scoped to the PeteDio-Labs org with
   **Organization permissions → Self-hosted runners: Read and write** (classic-token
   equivalent: `admin:org`). Prefer a short expiry + calendar reminder, or a GitHub App for
   rotation.
2. Store it in Vault — **by reference only, never in the repo**:
   ```
   vault kv put kv/iac/github-runner-pat pat=<the-PAT>
   ```

Registration tokens themselves expire in ~1h, so they are **minted at runtime** from this
PAT — never stored.

---

## Rebuild / register steps

1. **LXC** — `terraform apply` so the container exists (`module.runner` / `module.runner_2`
   in `environments/homelab/runner.tf`). Operator-only, in a no-apply window.

2. **Confirm the runner version pin** — `configure-runner.yml`'s `runner_version` is pinned
   (not `latest`). Check it against the current
   [actions/runner release](https://github.com/actions/runner/releases) and bump if needed;
   optionally set `runner_sha256` to the release's published linux-x64 SHA-256 to verify the
   download.

3. **Provision (Docker + register)** — resolve the PAT from Vault and pass it as a `no_log`
   `@file` extra-var (the repo convention):
   ```bash
   umask 077
   vault kv get -format=json kv/iac/github-runner-pat \
     | jq '{github_runner_pat: .data.data.pat}' > /tmp/runner-secret.json

   cd ansible
   # One box (first run on the new node), or drop --limit to do both:
   ansible-playbook playbooks/configure-runner.yml -e @/tmp/runner-secret.json --limit runner-233

   shred -u /tmp/runner-secret.json
   ```
   This imports `configure-runner-docker.yml` (Docker), installs the pinned actions-runner,
   mints a registration token, runs `config.sh --replace --unattended`, and installs +
   starts `actions.runner.PeteDio-Labs.<host>.service`.

4. **Verify green** — the runner shows **Idle** under the org's
   *Settings → Actions → Runners*, and a subsequent push-to-main `terraform` job picks up on
   `[self-hosted, linux, x64, homelab]`. Confirm the service:
   ```bash
   systemctl --type=service 'actions.runner.PeteDio-Labs.*' --no-legend
   ```

---

## Notes

- **Idempotent:** a converged runner is a no-op (install guarded by `creates:`; registration
  skipped while the `.runner` marker exists). To force a re-register (new labels/scope),
  add `-e runner_force_reconfigure=true`.
- **Per-node:** registration uses `inventory_hostname` for the runner name, so the same play
  serves both runner-232 and runner-233; their LXC differences (bridge/datastore/node) are
  in `runner.tf`, not here.
- **`--check`:** the binary download/extract diffs under `--check`; the `config.sh`/`svc.sh`
  command tasks are skipped there — do a real run in a no-apply window to actually register.
