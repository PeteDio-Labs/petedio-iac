# deploy-staging-249

Source: `.github/workflows/deploy-staging-249.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` only. No `pull_request` trigger, ever (PET-407). |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | `services/configure-staging.yml` against staging-249 (root). Configures the portfolio staging host. |
| **Vault** | OIDC login to `https://192.168.50.223:8200` as role `deploy-staging-249` (mount `jwt-github`). `scripts/ci-deploy.py` then reads the records the play needs and signs an SSH certificate. Secret values never reach the log. |
| **Secrets** | None in Actions. Credentials come from Vault by reference. |
| **Gates** | <br>• Dispatch only, `main` only. The Vault role `deploy-staging-249` binds `event_name = workflow_dispatch`, `ref = main` and this file's `workflow_ref` (`vault-config/deploy-hosts.tf`), so a push, schedule, pull request or other workflow mints nothing. <br>• A step refuses any ref but `main` and fails (it does not skip). <br>• `scripts/ci-deploy.py` proves the play matches exactly the expected hosts before it runs, and fails unless Ansible reports those hosts with `failed=0` and `unreachable=0`. <br>• The SSH certificate lasts 30 minutes and its principal opens only the named host. <br>• Runs in the `deploy-staging-249` concurrency group, so deploys of one host never overlap. |
| **Run it** | `gh workflow run deploy-staging-249.yml --ref main`. Fallback when CI or Vault is unreachable: `scripts/deploy-staging-249.sh` from the operator's machine. |

Read `docs/runbooks/host-deploys.md` for the one-time host trust of the Vault SSH CA. Without the Vault role the login answers 403. Without the trust the connection is refused. Both fail within a minute.
