# Per-role SSH access with the Vault SSH CA (PET-771)

Vault signs short-lived SSH certificates, one signing role per identity. A host accepts a
certificate only for the local users whose principals file names that role. This replaces the
shared `kv/iac/lxc-ssh` root key one consumer at a time (audit H6).

| Piece | Where |
|---|---|
| The CA and the signing roles | `environments/homelab/vault-config/ssh.tf` |
| Host trust and role users | `ansible/roles/ssh-ca`, run by `ansible/playbooks/configure-ssh-ca.yml` |
| Get a certificate | `scripts/ssh-ca-sign.sh <role> <public-key-file>` |

## Roles

| Role (principal) | Logs in as | TTL | Who signs it | Limits |
|---|---|---|---|---|
| `inventory-read` | `inventory`, no sudo | 30 min | the `PET-770` collector on 237 | `source-address` 237, no pty, no forwarding |
| `pedro` | `root` | 1 h | the break-glass token on 247 | pty only, `source-address` LAN, .86 mesh and tailnet |
| `lab-runner` | `root` on the nodes | 30 min | `lab-action.yml` on runner 232 or 233 | `source-address` 232 and 233, no pty |
| `search-deploy` | `root` on `ollama-246` only | 30 min | `petedio-search` `deploy.yml` on runner 232 or 233 | `source-address` 232 and 233, no pty; only `ollama-246` lists the principal |
| `deploy-plane`, `deploy-minio-data`, `deploy-metrics`, `deploy-lab-watchdog`, `deploy-codex-248` | `root` on one host each | 30 min | the `deploy-<name>.yml` workflow on runner 232 or 233 | `source-address` 232 and 233, no pty; only that host lists the principal. See `host-deploys.md` |

To add a role, add a `vault_ssh_secret_backend_role` and its signing policy in `ssh.tf`, and a
user and principal in `ssh_ca_users` (role defaults, or `host_vars` for one host).

## Trust the CA on `ollama-246` (`search-deploy`, PET-526)

`ollama-246` trusts no CA until this step, and the `configure-ssh-ca.yml` play cannot reach it
without the shared `lxc-ssh` key. To trust the CA without that key, dispatch `lab-action.yml` with
`action=playbook_apply` and `target=configure-ssh-ca-ollama-246.yml`. The play logs in to `pve01`
with the `lab-runner` certificate and runs `pct exec 246`. It waits for your tap on the
`lab-write` environment. Its last line names the counts it examined. After it, the
`petedio-search` deploy signs a `search-deploy` certificate and connects to the guest directly.

Apply `vault-config` first, because the `search-deploy` role must exist before a deploy can sign.

## Phase 1: turn on the CA and canary one host

1. To create the CA, run `scripts/apply-vault-config.sh` on 247 from the break-glass shell. To
   read the plan first, run it with `--plan-only`: it prints the plan and the destroy guard's
   verdict, then exits without applying. Read
   the plan: it adds the mount, the CA, two roles and one policy, and changes `breakglass-247`.
2. Check that Vault serves the key:
   `curl -s --cacert environments/homelab/vault-ca.crt https://192.168.50.223:8200/v1/ssh-client-signer/public_key`
   prints one `ssh-ed25519` line.
3. To trust the CA on the canary, run this from `ansible/`:
   `ansible-playbook playbooks/configure-ssh-ca.yml -e ssh_ca_targets=metrics-240 -e ansible_ssh_private_key_file=<file>`.
   A host does not trust the CA until this first run, so the first run logs in with the
   `kv/iac/lxc-ssh` key. Since `PET-725` only the break-glass token reads it. Write it to a
   `0600` file in a `mktemp -d` directory, with `trap 'rm -rf "$T"' EXIT` set first, so a
   failed play still deletes it (Pedro's decision, 2026-10-27). Pass the key with `-e`, not `--private-key`: the inventory sets
   `ansible_ssh_private_key_file`, and an inventory variable outranks the command-line flag.
   The last task names the host, the sshd unit and the principals files. The first play fails
   when `ssh_ca_targets` and `--limit` together name no host.
4. To prove the canary, sign a throwaway key for each role from the break-glass shell, then log in:
   - `inventory-read` as `inventory` from 237: logs in.
   - `inventory-read` as `inventory` from 247: `Permission denied`, because of `source-address`.
   - `inventory-read` as `root`: `Permission denied`.
   - `pedro` as `root`: logs in.
   - The old `lxc-ssh` key as `root`: still logs in. The role never edits `authorized_keys`.
   - A signing request for `inventory-read` that carries
     `critical_options={"source-address":"0.0.0.0/0"}`: Vault refuses it with
     `critical options not on allowed list`.

## Later phases

- Roll out by group (`-e ssh_ca_targets=<group>`), after the canary passes.
- `PET-770`: an AppRole for the collector on 237, bound to 237's `/32`, with the
  `ssh-sign-inventory-read` policy, and a seed script that Pedro runs.
- Roles `claude-ops` (247, non-root), `ci-deploy` (runner, signed per job through OIDC) and
  `node-admin` (root on the nodes, break-glass only).
- When no consumer reads `kv/iac/lxc-ssh` for login, remove its key from `authorized_keys`.
  Keep one static break-glass key outside Vault for a sealed or lost Vault.

## Limits

- Vault seals every night. A certificate cannot be signed while it is sealed, and
  `ssh-ca-sign.sh` exits non-zero then. A scheduled caller must report that, not skip.
- Revocation is by TTL. To cut a role off before its certificates expire, set `state: absent`
  on its `ssh_ca_users` entry, delete the entry, or remove the principal from the list, and
  re-run the play. The role removes every entry in the principals directory that is not a listed user's file, whatever its name or type (PET-784).
- A `pedro` certificate is root from anywhere on the LAN, the .86 mesh or the tailnet for its hour. The phone
  arrives through the pete-pi-1 subnet router, which rewrites its address to a LAN address.
- `prevent_destroy` guards the mount and the CA. To retire the CA, remove both `lifecycle`
  blocks in a reviewed PR first. `--allow-destroy` cannot override `prevent_destroy`.
- `create: true` creates or removes only an account whose GECOS field is
  `roles/ssh-ca (PET-771)`. It fails on an account that someone else made.
- CT 112 runs no sshd and stays reached through `pct exec`.
