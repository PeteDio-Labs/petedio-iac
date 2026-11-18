# branch-cleanup

Source: `.github/workflows/branch-cleanup.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with `mode` (`plan` or `delete`) and `repo`. |
| **Runner** | GitHub-hosted (`ubuntu-latest`) |
| **Touches** | Deletes branches whose tip equals a merged PR's head, in petedio-iac only (`github.token` scope). |
| **Vault** | None. |
| **Secrets** | `github.token` only. |
| **Gates** | <br>• `plan` lists and deletes nothing.<br>• `delete` waits on `lab-write`, then re-checks every branch against fresh reads.<br>• Another repo name fails at the first API read.<br>• `main` only; the log prints names, counts and short SHAs. |
| **Run it** | `gh workflow run branch-cleanup.yml --ref main -f mode=plan`. |


