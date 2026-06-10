# agent-loop role — autonomous coding loop host (LXC 242) — PET-125

Configures **agent-loop-242** (`192.168.50.242`, Ubuntu 24.04 LTS LXC, TF-created by
`environments/homelab/agent-loop.tf`): the box that runs the autonomous coding loop —
Claude Code working `agent-ok` **Platform** issues in `petedio-iac`. (242 = the next
free compute-block number: `.240` is burned by a stale router DHCP reservation, 241 =
openfaas.)

What the role installs (idempotent; a second run reports no changes):

- Base toolchain: `git`, `curl`, `build-essential`, `tmux`
- Node.js LTS (NodeSource, major pinned via `agent_loop_nodejs_major`)
- **Claude Code** (`npm i -g @anthropic-ai/claude-code`)
- **gh CLI** (official apt repo)
- **Bun** (`npm i -g bun`) — Co-latro's runtime + test runner, so the loop's Co-latro
  test gate runs (toggle with `agent_loop_install_bun`)
- Dedicated loop user **`agent`** (the loop never runs as root — Claude Code refuses
  `--dangerously-skip-permissions` as root), with operator SSH keys
  (`agent_loop_authorized_keys`, for direct `ssh agent@…`) and a `cc` alias
  (`agent_loop_cc_command`, default `claude`)
- **All active repos** cloned into a workspace mirroring `petedio-workspace` (see below;
  `update: false` — Ansible clones once, the loop owns syncing `main`, so a re-run never
  clobbers in-flight work)

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
the issue. The ops doc's repo map says which repo each issue maps to; today the loop
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
2. **Ansible**: `ansible-playbook playbooks/configure-agent-loop.yml` (then re-run to
   confirm idempotence — second run = no changes).
3. **Verify toolchain**: `claude --version`, `gh --version`, and `bun --version` as the
   `agent` user; confirm the public clones exist (`ls ~/work/petedio/{iac,media-iac,co-latro}`).
4. **Claude login** (interactive, browser auth): `ssh agent@192.168.50.242`, run
   `claude`, complete the login flow. (`gh auth login` likewise, or use `GH_TOKEN`.)
5. **Vault**: create `kv/services/agent-loop` with the scoped GitHub token (push
   branches + open PRs only, no merge); export it per the section above.
6. **(Optional) private repos**: once `gh`/`GH_TOKEN` works on the host, set
   `agent_loop_clone_private: true` and re-run the play to clone the parent
   `petedio-workspace` (meta-docs / `.agent/lessons.md`) + `co-latro-admin`.
7. **Start the loop**: attach to the tmux session **in the right repo dir** (Platform =
   `~/work/petedio/iac`; see *How the loop runs* above) and give Claude the loop prompt.
   Run the first iterations **supervised** before trusting it unattended.
