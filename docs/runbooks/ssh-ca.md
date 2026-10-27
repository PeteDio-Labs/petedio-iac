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
| `pedro` | `root` | 1 h | the break-glass token on 247 | pty only, no address bound |

To add a role, add a `vault_ssh_secret_backend_role` and its signing policy in `ssh.tf`, and a
user and principal in `ssh_ca_users` (role defaults, or `host_vars` for one host).

## Phase 1: turn on the CA and canary one host

1. To create the CA, run `scripts/apply-vault-config.sh` on 247 from the break-glass shell. Read
   the plan: it adds the mount, the CA, two roles and one policy, and changes `breakglass-247`.
2. Check that Vault serves the key:
   `curl -s --cacert environments/homelab/vault-ca.crt https://192.168.50.223:8200/v1/ssh-client-signer/public_key`
   prints one `ssh-ed25519` line.
3. To trust the CA on the canary, run
   `ansible-playbook playbooks/configure-ssh-ca.yml -e ssh_ca_targets=metrics-240` from `ansible/`.
   The last task names the host and the principals files it wrote. Use `ssh_ca_targets`, not
   `--limit`; the first play fails when the two together name no host.
4. To prove the canary, sign a throwaway key for each role from the break-glass shell, then log in:
   - `inventory-read` as `inventory` from 237: logs in.
   - `inventory-read` as `inventory` from 247: `Permission denied`, because of `source-address`.
   - `inventory-read` as `root`: `Permission denied`.
   - `pedro` as `root`: logs in.
   - The old `lxc-ssh` key as `root`: still logs in. The role never edits `authorized_keys`.

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
  on its `ssh_ca_users` entry, or remove the principal from the list, and re-run the play.
- A `pedro` certificate is root from any address for its hour. The phone reaches the LAN through
  a tailnet subnet router, so the role binds no `source-address`.
- CT 112 runs no sshd and stays reached through `pct exec`.
