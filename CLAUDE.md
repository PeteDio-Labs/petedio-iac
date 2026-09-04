# petedio-iac (Agent Context)

Greenfield **Terraform + Ansible** for the PeteDio homelab — an **AWS-shape** platform on Proxmox (LXC≈EC2, MinIO≈S3, Postgres≈RDS, Vault≈Secrets-Manager), built to graduate to real AWS by swapping provider / endpoint / variables, not a rewrite. One environment: `environments/homelab/`.

> Host inventory + IP/VMID scheme → the Linear doc **Homelab Inventory & IP/VMID Scheme** (don't re-derive it here). **`docs/GOTCHAS.md` is the single most useful read before touching anything.**

## Tooling
- **Terraform** for all infra — providers: `bpg/proxmox`, `hashicorp/vault`, `postgresql`, `cloudflare`. **Ansible** for host-level OS/service config (roles + playbooks).
- **State:** MinIO S3 backend (`.221`, bucket `tfstate`, versioned, `use_lockfile = true` — S3-native lock). **Never run concurrent applies** (versioning is the recovery net, not a lock substitute).
- **Secrets:** HashiCorp Vault (`.223`), reached in CI via **GitHub OIDC** (no static Actions secrets). **No secrets in code or PRs** — Vault paths by reference only.

## The co-ownership gotcha (read before touching Docker/containerd LXCs)
TF + Ansible **co-own** these LXCs: Proxmox's `root@pam` check rejects API tokens for `features{}`, so **TF creates the container** (with `features` in `ignore_changes`) and **Ansible sets `nesting`/`keyctl`** over SSH. Full detail + the rest of the hard-won quirks → `docs/GOTCHAS.md`.

## Layout
- `environments/homelab/` — the one env: per-host `*.tf` files + `vault-config/` (separate state).
- `modules/` — `proxmox-lxc`, `baremetal-host`, `postgres-db`, `cloudflare-ingress`.
- `ansible/` — `inventory/`, `playbooks/`, `roles/`.
- `docs/` — `GOTCHAS.md` + runbooks. `scripts/` — operational helpers.

## Workflow (trunk-based GitOps)
- Branch `pet-<n>-<slug>` off **fresh `main`** → PR → **squash-merge**. Mention `PET-<n>` in the PR.
- CI: **`validate` on PR** (GitHub-hosted, no Vault/LAN/state) and **`plan` + `apply` on merge** (self-hosted runner, LXC 232). There is no plan-on-PR (PET-104/163) — the authoritative plan is your local one or the apply-on-merge log.
- **Verify before done:** `terraform fmt`/`validate`/`plan` — and *read the actual plan* (a green check ≠ a good plan; an empty plan block is a failure). **Never `apply` by hand.**
- **Declare it, don't run it — IaC over hand fixes.** When a repair can be expressed as config, express it as config; see workflow rule 6 in the workspace `CLAUDE.md`. `removed { … lifecycle { destroy = false } }` replaces `terraform state rm` and **skips the refresh** for that resource, which is what lets it forget a guest on a node that no longer resolves. `import { to = … id = … }` replaces `terraform import`; `moved` replaces a rename-shaped `state mv`. Write a script only for what the language genuinely cannot say, and record the refusal verbatim in it — `removed` addresses a *resource*, never one instance of a `for_each`, and it cannot be paired with `import` to repoint an address the config still declares. `scripts/tf-state-repoint-pve01.sh` predates this rule; it is a one-shot repair for the rack loss, not a pattern to copy.
  - ⚠ **That script is scoped to `environments/homelab` in this repo only.** It repaired this state on 2026-09-04 and left `petedio-media-iac`'s state naming the dead node, which is why every media apply reported `1 to change` for a day (PET-332). A repair script's blast radius is the directory it `cd`s into — check whether a sibling state has the same damage.
- Minimal impact, root-cause, no temp hacks. Plan first for non-trivial (3+ step / architectural) work; if something goes sideways, STOP and re-plan.

## If you are the autonomous loop
Work **only** `agent-ok` **Platform** issues in this repo; **never merge** (the loop's token is scoped to push + open PRs). Follow the Linear doc **Agent Loop Operations** for the full per-iteration protocol.

## Writing style

Write in **Google developer documentation style** — the standing default for prose
in this repo: PR descriptions, commit bodies, work-item comments, docs, and code
comments.

- **Second person.** The reader is *you*; use *I* for yourself, never *we* for the reader.
- **Active voice.** Name who does the thing.
- **Conditions before instructions:** *To rebuild the index, run X* — not *Run X if
  you want to rebuild the index.*
- **Answer first**, detail after.
- **Cut filler:** *just*, *simply*, *easy*, *please note*, *in order to*. Never call
  something easy.
- **No time-anchored words** in durable prose: *currently*, *new*, *now*, *latest*,
  *existing*.
- **Sentence case** headings; code font for paths, commands, flags, and `PET-<n>` keys.
- Sentences under 26 words. Write *lets you* not *allows you to*, *run* not *execute*.

This governs how sentences are written, not how many. Don't restyle prose you aren't
already editing.
