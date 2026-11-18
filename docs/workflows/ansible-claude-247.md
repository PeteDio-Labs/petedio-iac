# ansible-claude-247

Source: `.github/workflows/ansible-claude-247.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with optional `mixup_probe`. No push trigger, no `pull_request` (PET-407). |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | The `claude-code` role on claude-247, and the Proxmox API for the `claude-247` token. |
| **Vault** | Role `claude-247-deploy` (binds `workflow_dispatch` and this file). Reads `kv/services/claude-workspace-mirror`, `claude-vault-push`, `claude-code-push`, `claude-ops-github` (GitHub App id, installation id, PEM), `kv/services/claude-247-pve`, `kv/iac/lxc-ssh`. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• Merging a role change does not deploy it; a person dispatches.<br>• `scripts/claude-247-extra-vars.sh` refuses App-id mix-ups; `mixup_probe=true` proves the refusal and never runs the play.<br>• One run at a time (`ansible-claude-247` group).<br>• Only the Mac can change this file: the 247 App has no `workflows` permission. |
| **Run it** | `gh workflow run ansible-claude-247.yml --ref main`. Fallback: `scripts/deploy-claude-247.sh`. |


