# agent-loop role — autonomous coding loop host (LXC 242) — PET-125

Configures **agent-loop-242** (`192.168.50.242`, Ubuntu 24.04 LTS LXC, TF-created by
`environments/homelab/agent-loop.tf`): the box that runs the autonomous coding loop —
Claude Code working `agent-ok` **Platform** issues in `petedio-iac`. (242 = the next
free compute-block number: `.240` is burned by a stale router DHCP reservation, 241 =
openfaas.)

What the role installs (idempotent; a second run reports no changes):

- Base toolchain: `git`, `curl`, `build-essential`, `tmux`
- Node.js LTS (NodeSource, major pinned via `agent_loop_nodejs_major`)
- **Claude Code** — `npm i -g @anthropic-ai/claude-code`, installed **as the `agent` user
  into a per-user npm prefix** (`~/.npm-global`, `agent_loop_npm_prefix`) so the loop can
  self-update it. A root-owned system prefix is the "no write permission to npm prefix"
  auto-update failure (PET-139).
- **gh CLI** (official apt repo)
- **Bun** (`npm i -g bun`, same per-user prefix as Claude Code) — Co-latro's runtime +
  test runner, so the loop's Co-latro test gate runs (toggle with `agent_loop_install_bun`)
- **IaC verify toolchain** (PET-131) so the loop can `fmt`/`validate`/`--syntax-check`/
  lint on-host:
  - **Terraform** — a pinned binary verified against its official SHA256 and dropped into
    `/usr/local/bin` (no HashiCorp apt repo); version + checksum are role defaults
    (`agent_loop_terraform_version` / `_sha256`, pinned ≥ 1.10, the repo's strictest
    `required_version`). The stray `~/.local/bin/terraform` hand-bootstrapped during
    PET-124 is removed (it shadowed `/usr/local/bin` on the agent's PATH).
  - **ansible-core**, **yamllint**, **ansible-lint** — per-user via `pipx` as the `agent`
    user (no root venv), plus Galaxy collections (`community.general`, `ansible.posix`,
    `community.postgresql`) from `files/requirements.yml` into `~agent/.ansible/collections`.
  - The `agent` user gets **no sudo** — the apt prereqs (`python3-venv`, `python3-pip`,
    `unzip`), a pip-installed **pipx ≥1.7.0** (24.04's apt ships 1.4.3, too old for
    `community.general.pipx` — PET-140), and the TF binary install because the role itself
    is applied privileged.
- Dedicated loop user **`agent`** (the loop never runs as root — Claude Code refuses
  `--dangerously-skip-permissions` as root), with operator SSH keys
  (`agent_loop_authorized_keys`, for direct `ssh agent@…`) and a `cc` alias
  (`agent_loop_cc_command`, default `claude`)
- **All active repos** cloned into a workspace mirroring `petedio-workspace` (see below;
  `update: false` — Ansible clones once, the loop owns syncing `main`, so a re-run never
  clobbers in-flight work)
- **Vault Agent** (PET-141, toggle `agent_loop_vault_agent_enabled`) — a pinned `vault`
  binary (`/usr/local/bin`, checksum-verified) + a systemd `vault-agent` service that
  auto-auths with the **read-only `agent-loop` AppRole** and renews a token into
  `~agent/.vault-token`, so the loop self-serves `kv/services/agent-loop` (e.g.
  `scripts/proxmox-ro-config.sh`'s Vault fallback) with no hand-exported env var and no
  claude restart. AppRole creds are operator-provisioned into `.secrets/` (see runbook).
- **MinIO client `mc`** (PET-135, reviewer loop; toggle `agent_loop_install_mc`) — a
  pinned, checksum-verified binary in `/usr/local/bin`, so the reviewer can append its
  JSONL eval rows to MinIO (`agent-evals/verdicts.jsonl`). The `mc alias` credentials are
  an operator step from Vault — see [`docs/runbooks/reviewer-loop.md`](../../../docs/runbooks/reviewer-loop.md).
- **Auto-rebase timer** (PET-148, toggle `agent_loop_rebase_timer_enabled`) — a systemd
  timer (`agent_loop_rebase_oncalendar`, default every 15 min) that runs
  `scripts/rebase-loop-prs.sh` as the loop user to rebase the loop's **own** open PRs onto
  `main` and force-push them (loop branches only — the script enforces a `^pet-` **and**
  loop-author guard, and only ever works in a throwaway `/tmp` clone), so plan-on-PR always
  reflects a fresh base. It self-serves `GH_TOKEN` from Vault (`kv/services/agent-loop`,
  field `github_token`) via the Vault Agent token, so no env secret is needed. The push uses
  the loop PAT (not the Actions `GITHUB_TOKEN`) specifically so it **re-triggers** plan-on-PR.

Run the role:

```sh
cd ansible/
ansible-playbook playbooks/configure-agent-loop.yml
```

## Workspace layout (PET-130) — mirrors `petedio-workspace`

The host reproduces the `petedio-workspace` parent + **gitignored nested children**
layout, so each repo sits where the workspace expects it. Workspace root:
`~agent/work/petedio` (`agent_loop_workspace`).

| Path (under the workspace root) | GitHub (`PeteDio-Labs/…`) | Visibility |
|---|---|---|
| `iac/` | `petedio-iac` | public |
| `media-iac/` | `petedio-media-iac` | public |
| `co-latro/backend/` | `co-latro-backend` (Bun) | public |
| `co-latro/frontend/` | `co-latro-frontend` (Vite/Bun) | public |
| `.` *(workspace root)* | `petedio-workspace` (meta-docs) | **private — opt-in** |
| `co-latro-admin/` | `co-latro-admin` | **private — opt-in** |

The four **public** repos clone with no auth. The two **private** ones (the parent
meta-docs + admin) need gh auth on the host, so they're behind `agent_loop_clone_private`
(default `false`) — flip it on **after** the agent user has a working `GH_TOKEN`/`gh`
login. Which repo a given issue maps to comes from the **Agent Loop Operations** ops doc,
not this role.

> [!IMPORTANT]
> **Working-dir change (was `~agent/work/petedio-iac`).** Before PET-130 the only clone
> was `~agent/work/petedio-iac`; it is now `~agent/work/petedio/iac`. Any tmux session,
> loop prompt, or muscle-memory `cd` that assumed the old path must be updated — see *How
> the loop runs* below.

## How the loop runs — a standing prompt, no shell wrapper

There is **no `run-loop.sh`**. The loop is just **Claude Code driven by a standing
prompt**, run as `agent` in a tmux session. Attach and start it:

```sh
ssh -t agent@192.168.50.242 tmux attach -t loop
# start the session (or cd) in the repo for the issue, e.g. a Platform issue:
#   cd ~/work/petedio/iac
# then run `cc` (= claude) and give it the loop prompt
```

> [!IMPORTANT]
> **tmux `loop` session start-dir.** With the PET-130 workspace move, the session must
> open in `~/work/petedio/iac` (not the old `~/work/petedio-iac`). If you create the
> session non-interactively, set the start dir explicitly, e.g.
> `tmux new-session -d -s loop -c ~/work/petedio/iac`. A Co-latro issue is worked from
> `~/work/petedio/co-latro/{backend,frontend}` instead.

The loop prompt points Claude at the Linear doc **Agent Loop Operations** (Knowledge
project), which holds the full per-iteration protocol: pick one `agent-ok` issue →
branch → implement → verify (**never apply**) → open a PR (**never merge**) → report on
the issue. Since PET-131 the on-host **verify** step is real: `terraform fmt -check`/
`validate`, `ansible-playbook --syntax-check`, `yamllint`, and `ansible-lint` all run
locally as the `agent` user. (`terraform plan` against the real backend still needs
operator-supplied MinIO/Vault creds and remains off-host — never run by the loop.) The ops doc's repo map says which repo each issue maps to; today the loop
works **Platform** (`iac/`) — broadening to the other repos is governed there, not here.

## Secrets — Vault path reference only, NOTHING baked in

**No token, no secret, lives in this repo or this role.** The loop's GitHub token is a
**scoped** token — push branches + open PRs only, **no merge** — stored at:

```
kv/services/agent-loop        (field: github_token)
```

The existing `ansible` Vault policy already reads `kv/data/services/*`, so no
policy change is needed when the secret is created. Pull it onto the host manually
(as `agent`), e.g.:

```sh
export VAULT_ADDR=https://192.168.50.223:8200 VAULT_CACERT=<path-to>/vault-ca.crt
export GH_TOKEN=$(vault kv get -field=github_token kv/services/agent-loop)
```

`gh` uses `GH_TOKEN` from the environment — prefer that over `gh auth login` so the
token never lands on disk.

## Post-merge provisioning runbook (manual, in order)

1. **Runner applies on merge** → LXC 242 created (TF). Pre-merge: the Ubuntu template
   must exist on pve01 (`pveam update && pveam download local
   ubuntu-24.04-standard_24.04-2_amd64.tar.zst`).
2. **Vault Agent creds (PET-141)** — before the Ansible run, create the read-only
   `agent-loop` AppRole and seed its creds locally (the play asserts they exist; skip with
   `agent_loop_vault_agent_enabled=false`):
   ```sh
   scripts/apply-vault-config.sh   # creates the agent-loop policy + AppRole (TF, operator-applied)
   # mint creds into the gitignored .secrets/ (needs the Vault root token, same as above):
   vault read  -field=role_id     auth/approle/role/agent-loop/role-id     > .secrets/agent-loop.role_id
   vault write -f -field=secret_id auth/approle/role/agent-loop/secret-id   > .secrets/agent-loop.secret_id
   ```
3. **Ansible**: `ansible-playbook playbooks/configure-agent-loop.yml` (then re-run to
   confirm idempotence — second run = no changes).
4. **Verify toolchain**: as the `agent` user — `claude --version`, `gh --version`,
   `bun --version`, and `command -v claude` → `~/.npm-global/bin/claude` (the per-user npm
   prefix, NOT `/usr/bin` — PET-139, so Claude Code's auto-update can write); and the IaC
   verify chain (PET-131): `terraform version` (must resolve
   to `/usr/local/bin/terraform`, i.e. `which terraform`), `ansible --version`,
   `yamllint --version`, `ansible-lint --version`, and `ansible-playbook --syntax-check`
   on a playbook. Vault Agent (PET-141): `systemctl status vault-agent` is active and, as
   the agent, `vault kv get -field=proxmox_ro_token kv/services/agent-loop` works (token
   read off `~/.vault-token`, no env var). Confirm the public clones exist
   (`ls ~/work/petedio/{iac,media-iac,co-latro}`). A second role run must report **no
   changes** (idempotent).
5. **Claude login** (interactive, browser auth): `ssh agent@192.168.50.242`, run
   `claude`, complete the login flow. (`gh auth login` likewise, or use `GH_TOKEN`.)
6. **Vault**: create `kv/services/agent-loop` with the scoped GitHub token (push
   branches + open PRs only, no merge); export it per the section above.
7. **(Optional) private repos**: once `gh`/`GH_TOKEN` works on the host, set
   `agent_loop_clone_private: true` and re-run the play to clone the parent
   `petedio-workspace` (meta-docs / `.agent/lessons.md`) + `co-latro-admin`.
8. **Start the loop**: attach to the tmux session **in the right repo dir** (Platform =
   `~/work/petedio/iac`; see *How the loop runs* above) and give Claude the loop prompt.
   Run the first iterations **supervised** before trusting it unattended.
