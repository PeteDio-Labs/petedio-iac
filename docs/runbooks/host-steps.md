# Host step runbooks

One section per recurring host step, so a session on 247 or Pedro's phone runs it from a
script without a thread to explain it (`PET-754`). Each section gives the precondition, the
command, the expected output and what a bad output looks like. The Friday hands-on file in the
project's `runbooks/` folder holds the dated steps; this file holds the repeatable ones.

Run every command from a fresh `main` of `petedio-iac`. No section places a credential by
hand. A script that needs a Vault token reads `$VAULT_TOKEN`, so start a break-glass shell
first (`vault-breakglass` on 247).

## Report OS patch state (`lab-updates.sh`)

- **Precondition:** SSH to `pve02` and `pve03` works from the session.
- **Command:** `./scripts/lab-updates.sh`
- **Expected:** one row per node and guest, the age of each apt list, and a last line that
  names the counts of hosts examined and read. Exit code 0.
- **Bad:** exit code 1, or a row that starts `ERR`. A host the script could not read is never
  counted as "0 upgradable". A list age of many days means the count undercounts.
- **Changes nothing:** the script runs no `apt-get update`, upgrade or reboot.

## Verify the whole lab (`lab-verify.sh`)

- **Precondition:** the LAN is reachable from the session.
- **Command:** `./scripts/lab-verify.sh` (add `--quiet` to print failures only).
- **Expected:** every hop passes, and the summary line reports the counts. Trust that line over
  any count written in a note.
- **Bad:** a failing hop names the service. A guest that moved nodes is found by the script,
  so a failure means the service is down, not that it moved.

## Apply `vault-config` (`apply-vault-config.sh`)

- **Precondition:** a Vault token in `$VAULT_TOKEN` (break-glass shell). The script refuses to
  run with no token and never prompts. The change is merged to `main` first.
- **Command:** `./scripts/apply-vault-config.sh`
- **Expected:** a plan, then an apply. Read the plan before you let it apply: it lists only the
  policies, roles or mounts the PR described, and zero resources to destroy.
- **Bad:** the script refuses a plan that destroys anything. Do not add `--allow-destroy`
  unless Pedro says so in the session's own chat for that run. The flag lasts one invocation.
- **After:** run `./scripts/vault-verify.sh`. Every check passes.

## Check the `lxc-ssh` key rotation (`rotate-lxc-ssh.sh --check`)

- **Precondition:** SSH to both nodes, and `$VAULT_TOKEN`.
- **Command:** `./scripts/rotate-lxc-ssh.sh --check`
- **Expected:** step 1 only. It reads the key pair, lists running containers and records which
  trust the old key. It changes nothing. The summary names what it examined.
- **Bad:** a container the script cannot see (a stopped one) is reported. The real rotation
  (`./scripts/rotate-lxc-ssh.sh`) runs only on Pedro's word after a clean check.

## Dispatch a read-only workflow

- **Precondition:** a session that may dispatch workflows. 247 gets HTTP 403 today (`PET-753`),
  so the Mac dispatches until that closes.
- **Command:** `gh workflow run <name>.yml --repo PeteDio-Labs/petedio-iac`, then
  `gh run watch`.
- **Expected:** the run finishes green and says what it examined, for example the paths read.
- **Bad:** a run that ends in seconds, or a green run that read nothing. Open the log and
  count what it examined before you report success.

## Seed or deploy a service (`seed-*.sh`, `deploy-*.sh`)

- **Precondition:** the PET item names the script and its order. A `seed-*.sh` script places a
  credential and runs only on Pedro's word. AppRole files sit in `.secrets/`.
- **Command:** the script by name, for example `./scripts/deploy-search.sh`.
- **Expected:** a `PLAY RECAP` with `failed=0 unreachable=0`, and a read-back line from the
  host. A seed script prints lengths only and reads each value back.
- **Bad:** `failed` or `unreachable` above zero. Stop at the first failure and post the raw
  output on the PET item.

## Vault is sealed

- **Precondition:** none. Vault restarts nightly and seals; the unseal watcher on the Pi
  (`deploy-vault-unseal.sh`) unseals it within minutes.
- **Command:** `curl -s --cacert environments/homelab/vault-ca.crt https://192.168.50.223:8200/v1/sys/seal-status`
- **Expected:** `"sealed": false`.
- **Bad:** `"sealed": true` for more than 10 minutes. Unsealing needs the key, which lives in
  the Mac's Keychain and nowhere else. Follow `vault/Systems/vault-and-secrets.md`.
