# plane-sync (reusable)

Source: `.github/workflows/plane-sync.yml`

| | |
|---|---|
| **Trigger** | `workflow_call`, `pull_request_target`, `workflow_dispatch`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Moves a Plane work item's state on PR events through `scripts/plane-sync.sh`. Never fails a build. |
| **Vault** | Role `plane-ci`, reads `kv/services/plane` (`api_key`) only. The caller's repo must be in `var.plane_repos` (`vault-config/variables.tf`). |
| **Secrets** | None in Actions. |
| **Gates** | <br>• `pull_request_target` runs main's copy and never checks out the PR head; it reads only event metadata.<br>• The `plane-ci` policy must never widen to Proxmox, MinIO or Cloudflare.<br>• Without an API key it warns and skips; the nightly reconciler catches the miss. |
| **Run it** | Called from each repo's `plane-sync-caller.yml`. Threads do not call Plane directly; they queue changes in `petedio-pm`. |


