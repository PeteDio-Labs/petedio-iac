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
- Dedicated loop user **`agent`** (the loop never runs as root — Claude Code refuses
  `--dangerously-skip-permissions` as root), with operator SSH keys
  (`agent_loop_authorized_keys`, for direct `ssh agent@…`) and a `cc` alias
  (`agent_loop_cc_command`, default `claude`)
- Clone of `petedio-iac` at `~agent/work/petedio-iac` (`update: false` — Ansible clones
  once; the loop owns syncing `main`, so a re-run never clobbers in-flight work)

Run the role:

```sh
cd ansible/
ansible-playbook playbooks/configure-agent-loop.yml
```

## How the loop runs — a standing prompt, no shell wrapper

There is **no `run-loop.sh`**. The loop is just **Claude Code driven by a standing
prompt**, run as `agent` in a tmux session. Attach and start it:

```sh
ssh -t agent@192.168.50.242 tmux attach -t loop
# then run `cc` (= claude) and give it the loop prompt
```

The loop prompt points Claude at the Linear doc **Agent Loop Operations** (Knowledge
project), which holds the full per-iteration protocol: pick one `agent-ok` Platform
issue → branch → implement → `fmt`/`validate`/`plan` (**never apply**) → open a PR
(**never merge**) → report on the issue. Scope is `petedio-iac` / **Platform only** —
never Co-latro.

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
3. **Verify toolchain**: `claude --version` and `gh --version` as the `agent` user.
4. **Claude login** (interactive, browser auth): `ssh agent@192.168.50.242`, run
   `claude`, complete the login flow. (`gh auth login` likewise, or use `GH_TOKEN`.)
5. **Vault**: create `kv/services/agent-loop` with the scoped GitHub token (push
   branches + open PRs only, no merge); export it per the section above.
6. **Start the loop**: attach to the tmux session and give Claude the loop prompt (see
   *How the loop runs* above). Run the first iterations **supervised** before trusting
   it unattended.
