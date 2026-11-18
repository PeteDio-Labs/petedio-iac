# keys

Source: `.github/workflows/keys.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with `mode` (`list`, `sync`, `rotate`, `renew`, `reissue`), `agent`, `pet`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Cloudflare Access service tokens for the agents named in `secrets/callers.yml`; Vault records under `kv/callers/edge`. |
| **Vault** | `keys-list` reads metadata under `kv/callers/edge` only. `keys-sync` also writes there and reads `kv/services/keys-cloudflare`, whose token edits Access service tokens only. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• `list` needs no approval.<br>• `sync`, `rotate`, `renew` and `reissue` wait on `lab-write`, and the apply job refuses unless it computes the plan job's digest.<br>• Only `main`, `workflow_dispatch` and this file mint either role; `keys-sync` also binds `lab-write`.<br>• `scripts/keys.py` prints names, versions and dates, masks secrets and never prints a Cloudflare response body. Owners read values from Vault. |
| **Run it** | `gh workflow run keys.yml --ref main -f mode=list`. See `docs/runbooks/keys.md`. |


