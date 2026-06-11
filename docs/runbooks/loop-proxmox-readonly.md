# Runbook — read-only Proxmox access for the agent-loop host

**Why this exists.** The autonomous loop is assigned *brownfield captures* (porting a
running LXC into `petedio-iac` via `terraform import`). For the import's first plan to be
a **no-op**, the Terraform must match the container's live config — cores, memory, rootfs
size + datastore, template, `unprivileged`, and any extra mount points. The loop is
author-only and cannot SSH or run Terraform against live infra, so without a way to *read*
the running config it would have to **guess** specs on live, load-bearing hosts (e.g. the
Nexus registry, whose blob store is a load-bearing NFS mount). Guessing risks a
destroy/replace plan — exactly what the hard rules say to stop on.

The fix is a **read-only** Proxmox API token. Reading config is a different blast radius
than mutating: a `PVEAuditor` token can enumerate config/status cluster-wide but **cannot
create, modify, or destroy anything**. So the loop can ground-truth a capture itself while
`apply` / `import` / state edits / SSH-to-configure remain forbidden.

> **Scope reminder.** This unblocks the **Terraform/import** half of a capture. The
> **Ansible "match the running service"** half (how Nexus/Authentik are installed and
> configured *inside* the guest) still needs in-container truth — that's SSH-into-the-guest,
> which stays forbidden. Supply that per-capture.

## One-time setup (operator, out-of-band — the loop cannot do this)

Run on the node as `root@pam` (token mint + ACL need real `root@pam`, not an API token —
see the features gotcha in `docs/GOTCHAS.md`):

```sh
# 1. Mint a privsep token (its own perms, independent of the user — none until granted)
pveum user token add petedio@pam loop-ro --privsep 1

# 2. Grant it read-only, cluster-wide
pveum acl modify / --tokens 'petedio@pam!loop-ro' --roles PVEAuditor

# 3. Seed Vault (the `ansible` policy already reads kv/data/services/* — no policy change,
#    same as the agent-loop github_token)
vault kv patch kv/services/agent-loop \
  proxmox_ro_token='petedio@pam!loop-ro=<secret-from-step-1>'
```

On the loop host (as `agent`), export it for the session (alongside `GH_TOKEN`):

```sh
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=<repo>/environments/homelab/vault-ca.crt
export PROXMOX_RO_TOKEN="$(vault kv get -field=proxmox_ro_token kv/services/agent-loop)"
```

`scripts/proxmox-ro-config.sh` also falls back to reading the field from Vault directly if
`PROXMOX_RO_TOKEN` isn't exported (needs `VAULT_TOKEN`).

## Using it

```sh
# Nexus registry, LXC 106 on pve01:
scripts/proxmox-ro-config.sh pve01 106

# Authentik, LXC 119 on pve01:
scripts/proxmox-ro-config.sh pve01 119
```

It prints the guest's config JSON (the `pct config` equivalent: `cores`, `memory`, `swap`,
`rootfs`, `mp0…`, `net0`, `ostype`, `unprivileged`, `onboot`, …) — everything needed to map
onto `modules/proxmox-lxc` and design a no-op import. The token is **never printed**.

`<node>` maps `pve01`→`.10`, `pve02`→`.11`; override with `PROXMOX_RO_ENDPOINT`. TLS is
`insecure` (self-signed homelab cert, matching `provider "proxmox" { insecure = true }`).

## Guardrails (proposed amendment to **Agent Loop Operations**)

The loop never edits the ops doc; **the operator** should fold this into the hard rules:

> Read-only Proxmox API introspection is **permitted** (config/status via the `PVEAuditor`
> token / `scripts/proxmox-ro-config.sh`). `terraform apply`/`import`, state mutation,
> SSH-into-live-hosts to configure, and reading/writing secrets remain **forbidden**.

## Verifying read-only

A mutation attempt with this token must fail. For example, a `POST`/`PUT` to a config
endpoint should return `403 Permission check failed` — `PVEAuditor` grants `*.Audit`
only. If a write ever succeeds, the ACL is wrong (it was granted more than `PVEAuditor`):
stop and re-scope before using the token from the loop.
