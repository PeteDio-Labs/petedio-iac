# Host deploys from GitHub Actions

Six host configurations deploy from a `deploy-<name>.yml` workflow instead of a script that an
operator runs. Each workflow logs in to Vault through GitHub OIDC, reads only that deploy's
records, signs a 30-minute SSH certificate for one principal, and connects to one host with it.
None of these six deploys reads the shared `kv/iac/lxc-ssh` key. `deploy-claude-247.sh`, `deploy-pete-bot.sh`, `deploy-media-dash.sh`, `deploy-search.sh` and `ansible-claude-247.yml` still do. The pattern is the `petedio-search` deploy
(`search-cd`, `search-deploy`, PET-526, PET-771).

| Workflow | Playbook | Host | Vault role (OIDC) | SSH principal |
|---|---|---|---|---|
| `deploy-plane.yml` | `configure-plane.yml` | `plane-235` | `deploy-plane` | `deploy-plane` |
| `deploy-minio-data.yml` | `configure-minio-data.yml` | `minio-data-245` | `deploy-minio-data` | `deploy-minio-data` |
| `deploy-metrics.yml` | `configure-metrics.yml` | `metrics-240` | `deploy-metrics` | `deploy-metrics` |
| `deploy-lab-watchdog.yml` | `configure-lab-watchdog.yml` | `claude-247` | `deploy-lab-watchdog` | `deploy-lab-watchdog` |
| `deploy-codex-248.yml` | `configure-codex.yml` | `codex-248` | `deploy-codex-248` | `deploy-codex-248` |
| `deploy-backup-store.yml` | `configure-backup-store.yml` | `pve01`, `pve02`, `pve03` | `deploy-backup-store` | `deploy-backup-store` |
| `deploy-staging-249.yml` | `configure-staging.yml` | `staging-249` | `deploy-staging-249` | `deploy-staging-249` |

`ansible-claude-247.yml` already deploys `claude-247`'s identities. It still reads the shared
key. Moving it to a `deploy-claude-247` principal is a separate change.

## Run a deploy

To deploy, dispatch the workflow on `main`:

```
gh workflow run deploy-plane.yml --ref main
```

A thread dispatches it with the GitHub tools it already has. The job fails unless Ansible
reports every expected host with `failed=0` and `unreachable=0`. The last log line names the
hosts the play matched, the hosts the recap reported, and the changed, failed and unreachable
counts.

A dispatch from any ref but `main` fails in its first step. A dispatch needs no approval. It deploys code that is already on `main`, which a review
approved, the same as the `petedio-search` and `petedio-media-control` deploys on merge.

## One-time setup

Do these in order, once.

1. **Apply `vault-config`.** On the Mac, from the repository root:
   ```
   export VAULT_ADDR=https://192.168.50.223:8200
   export VAULT_CACERT="$PWD/environments/homelab/vault-ca.crt"
   ./scripts/apply-vault-config.sh --plan-only
   ./scripts/apply-vault-config.sh
   ./scripts/vault-verify.sh
   ```
   The plan adds 6 `vault_ssh_secret_backend_role.host_deploy`, 6 `vault_policy.host_deploy` and
   6 `vault_jwt_auth_backend_role.host_deploy` (18 to add), and destroys nothing.
2. **Trust the CA on the five guests, and list the new principal on the nodes.** Dispatch `lab-action.yml` with `action=playbook_apply`
   and `target=configure-ssh-ca-deploy-hosts.yml`. The check runs first with no approval. Approve
   the `lab-write` environment on the run page in a browser: the GitHub iOS app doesn't show the
   button. One tap covers the five guests and the three nodes' principals files.
3. **Dispatch any deploy.** The first run is the first certificate login to that host.

`backup-store` signs its own `deploy-backup-store` principal, not `lab-runner`, so a dispatch never gets the principal that `lab-action.yml` gates behind the `lab-write` tap. Step 2 lists it on the nodes.

## What a deploy writes

The play configures the host as before. Secrets travel in an extra-vars file in a `0700`
directory, never as arguments, and every value is masked in the log before anything runs. The
certificate and key live in the same directory and are deleted when the job ends, even on
failure. The Vault token is revoked as soon as the certificate is signed.

## Limits

- The `lab-write` gate covers the trust play only. A deploy workflow has no approval step.
- The five guest deploys set `StrictHostKeyChecking=no`, as `ansible-claude-247.yml` does. The
  node deploy (`backup-store`) checks the runner's pinned node host keys.
- Vault seals nightly. A sealed Vault fails the login in the first minute.
- A change to a Vault policy in `deploy-hosts.tf` needs a `vault-config` apply before the
  workflow sees it.

## Still by hand

| Script | Why it stays |
|---|---|
| `deploy-vault-unseal.sh` | The Vault unseal key lives in the Mac Keychain. A runner or Vault cannot hold the key that opens Vault. |
| `deploy-uptime-kuma.sh` | The target, `pete-pi`, is a Raspberry Pi that no node reaches with `pct exec`, and it logs in as `pedro` with its own key. The first run also seeds `kv/services/uptime-kuma` from the Keychain root token. It needs a decision on how a runner reaches the Pi. |

## Related

- `docs/runbooks/ssh-ca.md` for the CA and its signing roles.
- `environments/homelab/vault-config/deploy-hosts.tf` for the roles and policies.
- `scripts/ci-deploy.py` for what each deploy stages.
