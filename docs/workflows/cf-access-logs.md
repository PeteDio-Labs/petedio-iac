# cf-access-logs

Source: `.github/workflows/cf-access-logs.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with `since`, `until` (UTC, like `2026-11-18T05:30:00Z`), `app` (optional hostname fragment) and `pet`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Reads Cloudflare Access authentication logs. Changes nothing. |
| **Vault** | `cf-logs-read` reads `kv/data/services/cloudflare-logs` only: a Cloudflare token with Account > Access: Audit Logs > Read, plus the account id. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• No approval: the token is read-only.<br>• Only `main`, `workflow_dispatch` and this file mint the role (`vault-config/cf-logs.tf`).<br>• `scripts/cf-access-logs.py` prints the app, action, allowed flag, identity provider name and time. It never prints an email, IP address, ray id or response body, and it exits 1 on an empty window. |
| **Run it** | `gh workflow run cf-access-logs.yml --ref main -f since=2026-11-18T05:30:00Z -f until=2026-11-18T07:00:00Z`. Seed the token first with `scripts/seed-cloudflare-logs.sh`. |
