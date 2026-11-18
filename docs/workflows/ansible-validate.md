# ansible-validate

Source: `.github/workflows/ansible-validate.yml`

| | |
|---|---|
| **Trigger** | `pull_request` and `push` (path filtered). |
| **Runner** | GitHub-hosted (`ubuntu-latest`) |
| **Touches** | Nothing. Static checks only: `--syntax-check` on every playbook and `ansible-lint` over `roles/` and `playbooks/` at the `production` profile. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | <br>• Each step counts what it reads and refuses zero, so a check over an empty glob is red.<br>• No ignore file. A suppression is a `# noqa: <rule>` at its site with the reason above it. |
| **Run it** | Open a PR. Locally: `ansible-lint` from `ansible/`. |


