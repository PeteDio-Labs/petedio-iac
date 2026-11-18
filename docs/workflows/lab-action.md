# lab-action

Source: `.github/workflows/lab-action.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with inputs `action`, `target`, `args`, `pet`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | `lab_verify` (`scripts/lab-verify.sh --quiet`, creates and deletes temporary storage files), `lab_updates`, `lab_probe` (one read-only probe inside LXC 237: journal, mtrace, media_ask, guests, health, backup_jobs, schedule), `repo_vars` (names in `scripts/lab-repo-vars.txt`), `playbook_check` and `playbook_apply` on the Proxmox node groups. |
| **Vault** | Role `lab-action-read`, bound to ref, event and this file (`vault-config/auth.tf`). |
| **Secrets** | None in Actions. |
| **Gates** | <br>• Only `playbook_apply` waits on `lab-write` (Pedro approves; `main` only).<br>• A playbook must be listed in `scripts/lab-playbooks.txt` and pass `scripts/lab-playbook-guard.py`, which refuses an unmarked `check_mode: false` task.<br>• The `run` job checks first; the `apply` job runs the same commit.<br>• The log is public: status and counts only, key-shaped strings masked, no `--diff` to Ansible.<br>• No concurrency group, so a newer dispatch never cancels an older read. |
| **Run it** | `gh workflow run lab-action.yml --ref main -f action=lab_verify -f pet=PET-<n>`, then read the run log. For `playbook_apply`, post the run link and Pedro taps approve. |

A check cannot see `command` and `shell` tasks, because Ansible skips them in check mode. Read the check's skipped count, not only its changed count, before you approve an apply.
