# blast-radius

Source: `.github/workflows/blast-radius.yml`

| | |
|---|---|
| **Trigger** | `pull_request` and `workflow_call` (other repos call it). |
| **Runner** | GitHub-hosted (`ubuntu-latest`), never the homelab runner, no `id-token`. |
| **Touches** | Reads changed paths and labels the PR tier-0, tier-1 or tier-2. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | <br>• Classifies only. It merges nothing and is not a branch-protection gate (Free plan).<br>• tier-0 cannot change desired state or a trust boundary; tier-1 changes what an operator can run; tier-2 runs on merge, mints credentials or moves the trust boundary.<br>• Other repos fetch the classifier from petedio-iac `main`, so one edit changes every repo. |
| **Run it** | Open a PR. The merge desk reads the tier (`scripts/pr-blast-radius.py`). |


