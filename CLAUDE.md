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
- CI on the self-hosted runner (LXC 232): **`terraform plan` on PR, `apply` on merge**.
- **Verify before done:** `terraform fmt`/`validate`/`plan` — and *read the actual plan* (a green check ≠ a good plan; an empty plan block is a failure). **Never `apply` by hand.**
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
