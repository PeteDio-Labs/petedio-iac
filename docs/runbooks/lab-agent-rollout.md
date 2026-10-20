# Roll out lab-agent and the lab MCP

This runbook lists the steps that put `lab-agent` on 237 and publish its MCP at `https://pdlab.dev/mcp/lab`. Run the steps in order. Each step names the PR it follows and the output that proves it.

The steps belong to `PET-675`, `PET-674`, `PET-670`, `PET-667` and `PET-671`. A host session runs them from this file and posts the raw output on the PET item.

## Before you start

- Run every step from the repository root of a checkout of `main` after the named PR merges. Each `cd` below runs in a subshell, so the next step starts at the root again.
- Run `terraform` and `ansible` steps on the Mac. The Mac holds the Vault admin token and the Ansible AppRole files.
- Never paste a credential into a chat or a PR. The seed scripts read and place credentials.

## Order

| # | Merge | Then run | Proof |
|---|---|---|---|
| 1 | [petedio-iac#461](https://github.com/PeteDio-Labs/petedio-iac/pull/461), [petedio-iac#459](https://github.com/PeteDio-Labs/petedio-iac/pull/459) and [petedio-iac#460](https://github.com/PeteDio-Labs/petedio-iac/pull/460) | `scripts/apply-vault-config.sh` | the plan lists the changes below, and the apply ends with `0 to destroy` |
| 2 | none | `scripts/seed-claude-ops-ansible-approle.sh` | the script prints the token's policies and three capabilities |
| 3 | none | `ansible-playbook playbooks/mint-pve-audit-token.yml -e pve_client=lab-agent` from `ansible/` | the play ends with `failed=0` |
| 4 | none | `scripts/seed-lab-agent.sh` | the script ends at `Done` and names no missing field |
| 5 | [pete-bot#37](https://github.com/PeteDio-Labs/pete-bot/pull/37), then [pete-bot#38](https://github.com/PeteDio-Labs/pete-bot/pull/38) | none | the deploy installs `lab-agent` and its `/health` reports every dependency up |
| 6 | [pete-bot#39](https://github.com/PeteDio-Labs/pete-bot/pull/39) and its plain-text change [pete-bot#40](https://github.com/PeteDio-Labs/pete-bot/pull/40) | none | `journalctl -u lab-agent` shows `drift check scheduled` |
| 7 | [petedio-iac#462](https://github.com/PeteDio-Labs/petedio-iac/pull/462) | `terraform output -raw lab_mcp_access_aud`, then the follow-up in step 7 below | an unauthenticated request to `https://pdlab.dev/mcp/lab` returns 401 |

Merge `pete-bot#38` after step 1. Until the apply runs, the `pete-bot-cd` role cannot read the lab-agent paths, and the deploy fails on a Vault 403.

## Step 1: apply the Vault config

One run covers all three PRs. Read the plan before you confirm it.

Expected changes:

- `#461`: two in-place updates to `bound_claims`, on `github-actions` and `openfaas-ci`.
- `#459`: two additions, the `ansible-247` policy and AppRole.
- `#460`: the `lab-agent-presence` policy, plus a change to the `pete-bot-cd` policy.

Stop if the plan destroys anything.

```bash
cd ~/petedio/iac && git checkout main && git pull --ff-only
./scripts/apply-vault-config.sh
```

After the apply, the next merge that touches `*.tf` proves `github-actions`, and the next palworld change proves `openfaas-ci`. If either login returns 403, run `scripts/diag-oidc.sh` (with `JWT_ROLE=openfaas-ci` for the second) and compare the claims.

## Step 2: place the 247 AppRole

The script mints a `secret_id`, delivers two files to CT 247 and proves the login. It prints only policies and capabilities.

```bash
./scripts/seed-claude-ops-ansible-approle.sh
```

Add `--rotate` to replace the `secret_id`. When the destroy of the old one fails, the script exits non-zero and keeps the old accessor. Re-run it to retry.

## Step 3: mint the lab-agent Proxmox token

```bash
(cd ansible && ansible-playbook playbooks/mint-pve-audit-token.yml -e pve_client=lab-agent)
```

The token has the `PVEAuditor` role and goes to `kv/services/lab-agent-pve`.

## Step 4: seed lab-agent

PeteDio-Labs disables deploy keys, so lab-agent reads the private `petedio-vault` with the read-only `petedio-workspace-mirror` App. The script mints nothing for it. It checks that `kv/services/claude-workspace-mirror` holds `app_id`, `installation_id` and `app_pem`, and stops with a message when one is missing.

If it stops on the mirror App, run `scripts/seed-workspace-mirror-vault.sh`, then run the seed again.

```bash
./scripts/seed-lab-agent.sh
```

The script writes whichever of `ask_token`, `vault_token` and `vault_token_accessor` is absent, and prints no value. Post the field names it reports on `PET-670`.

## Step 5: deploy

Merging `pete-bot#38` deploys on merge. To check the result from 237:

```bash
systemctl is-active lab-agent
curl -s http://127.0.0.1:3016/health
```

A healthy answer lists every dependency as up. A dependency that is down fails the deploy by design.

## Step 6: confirm the drift check

The check runs at 11:15Z. The local API listens on `127.0.0.1:3016`. Port 3017 is the MCP listener, which stays off until step 7.

To run the check now, send the ask bearer from the env file on 237. The `printf` builtin and the stdin header keep the bearer out of the process arguments and out of any log:

```bash
sudo bash -c 'tok=$(sed -n "s/^LAB_ASK_TOKEN=//p" /etc/lab-agent/lab-agent.env)
  printf "authorization: Bearer %s\n" "$tok" |
  curl -s -X POST -H @- http://127.0.0.1:3016/v1/drift/run'
```

The answer names the kind of outcome (`clean`, `drift` or `read-failed`) and what the run read. A `clean` run sends no DM. A `read-failed` run sends a DM that says the check examined nothing.

## Step 7: turn the MCP on

The MCP stays off while `lab_agent_access_aud` is empty. After `petedio-iac#462` applies:

1. Read the audience tag: `(cd environments/homelab && terraform output -raw lab_mcp_access_aud)`.
2. Set `lab_agent_access_aud` to that value in a one-line PR. A thread opens it.
3. After that PR merges and `deploy-pete-bot.sh` runs, check the edge:

```bash
curl -sI https://pdlab.dev/mcp/lab | head -1
```

Expect `HTTP/2 401`. Then add the connector `https://pdlab.dev/mcp/lab` on claude.ai in a browser. A request from the Mac straight to `192.168.50.237:3017` must time out, because the firewall admits only LXC 112.

## Patch report (`PET-679`)

`scripts/lab-updates.sh` reads OS patch state for each node and running guest. It runs no `apt update` and changes nothing. Run it on 247 and post the raw output, the exit code and the last line:

```bash
./scripts/lab-updates.sh; echo "exit=$?"
```

A nonzero `unreadable` count or exit 1 is a finding. Post it as is.
