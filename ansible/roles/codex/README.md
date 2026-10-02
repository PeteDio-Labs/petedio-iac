# codex role (PET-553)

Installs the Codex CLI on `codex-248` and leaves it ready for unattended runs
(`codex exec`), once a person signs it in to OpenAI. The host is the reviewer for the
`PET-549` proof of concept: a Claude session implements and opens a pull request, Codex
reviews it with comments, and Pedro decides the merge. Pedro chose that split on 2026-10-01.

| | |
|---|---|
| Host | `codex-248`: `192.168.50.248`, VMID 248, pve03 |
| Terraform | `environments/homelab/codex.tf`, which also declares the guest firewall |
| Playbooks | `playbooks/configure-pve-firewall.yml` once, then `scripts/deploy-codex-248.sh`, which runs `playbooks/configure-codex.yml` |
| Runs as | `codex`, a non-root user with no sudo |
| Codex | pinned by `codex_version` and `codex_sha256` in `defaults/main.yml` |
| Container features | `nesting=1` only, declared in `roles/lxc-features` |

## The boundaries, and where each lives

| Boundary | Where | Who can change it |
|---|---|---|
| No route to `192.168.0.0/16`, the tailnet or other private ranges, except Plane's API on `192.168.50.235:8080` | Guest firewall, `codex.tf` | A merged Terraform change |
| No `danger-full-access` sandbox | `/etc/codex/requirements.toml`, root-owned | Root on the host |
| Read code and comment on pull requests, and nothing more | The `petedio-codex-review` App's permissions | Pedro, in GitHub |
| Comment on a Plane work item as `codex`, never as Pedro | The `codex` Plane user, Member on PET | Pedro, in Plane |
| What the worker is told | `~/.codex/AGENTS.md` | The session user. It is guidance, not a boundary |

## Bring the host up

1. Merge the Terraform change. The apply creates CT 248 and its firewall rules.
   Then run `playbooks/configure-lxc-features.yml`, and restart 248 with `pct reboot 248`
   on pve03, so the sandbox can create its user namespace.
2. To turn the datacenter firewall on, run the firewall play once. Preview it first:

   ```bash
   ansible-playbook playbooks/configure-pve-firewall.yml --check --diff
   ansible-playbook playbooks/configure-pve-firewall.yml
   ```

3. Configure the host:

   ```bash
   ansible-playbook playbooks/configure-codex.yml
   ```

4. To prove the firewall, run these from the host. The first two must fail at once with a
   refusal, and the last two must succeed:

   ```bash
   ssh codex@192.168.50.248 'curl -sS -m 5 http://192.168.50.11:8006'
   ssh codex@192.168.50.248 'curl -sS -m 5 http://192.168.86.1'
   ssh codex@192.168.50.248 'curl -sS -o /dev/null -w "%{http_code}\n" https://api.github.com'
   ssh codex@192.168.50.248 'curl -sS -o /dev/null -w "%{http_code}\n" https://api.openai.com/v1/models'
   ```

## Sign in to OpenAI

Codex signs in to a ChatGPT account. The host has no browser, so use the device code flow:

1. `ssh codex@192.168.50.248`
2. `codex login --device-auth`. Open the URL it prints on any device, sign in, and enter
   the code.
3. `codex login status` reads `Logged in using ChatGPT`.

The token lands in `~/.codex/auth.json`, because `/etc/codex/config.toml` sets
`cli_auth_credentials_store = "file"`. Never copy that file off the host.

## Test the sandbox

Codex runs each command inside bubblewrap, which creates a user namespace. In a Proxmox
container, the AppArmor profile denies that unless the container has `nesting=1`. Without
it, every command fails with `bwrap: Creating new namespace failed: Permission denied`.
`roles/lxc-features` declares `nesting=1` for 248, and this role fails if
`unshare --user` fails.

These tests need no sign-in. To run them, connect as `codex` and `cd ~/work`:

```bash
codex sandbox -c 'sandbox_mode="workspace-write"' -- touch ~/work/inside.txt
codex sandbox -c 'sandbox_mode="workspace-write"' -- touch ~/outside.txt
codex sandbox -c 'sandbox_mode="danger-full-access"' -- true
```

On 2026-09-30, the three tests behaved as follows:

| Test | Result |
|---|---|
| A write inside `~/work` | Succeeds |
| A write outside `~/work` | `Read-only file system` |
| `danger-full-access` | Codex refuses to start: requirements do not allow it with `approval_policy = "never"` |

Under `workspace-write`, `curl https://api.github.com` returns 200, and a LAN address is
refused by the guest firewall. Under the default read-only mode, the sandbox has no
network.

## Spend the Plus allowance carefully

The account is ChatGPT Plus. Every run spends a 5-hour window and a weekly window, which
Pedro's own Codex use shares, and the account has no paid credits. The role sets three
things for that:

| Setting | Value | Why |
|---|---|---|
| `model` | `gpt-6.1-sol` | The catalog's model for getting the most from an allowance |
| `model_reasoning_effort` | `low` | The model's default. Raise it with `-c` for one run |
| `features.fast_mode` | `false` | The Fast tier spends more of the allowance |

To start a worker run, check the allowance first:

```bash
codex-quota && codex exec ...
```

`codex-quota` reads both windows without starting a run. It exits 1 when either window
reaches its limit in `defaults/main.yml`, and 2 when it cannot read them. The script lists a free rate-limit reset when one exists.
Only Pedro spends it, from the TUI or ChatGPT.

## Give the reviewer its identities

The reviewer holds two credentials, and each comes from Vault through a seed script that
Pedro runs. Nothing places either one by hand.

| Identity | Vault path | Seeded by | On the host |
|---|---|---|---|
| The `petedio-codex-review` GitHub App: contents read, pull requests write, metadata read, on every PeteDio-Labs repository | `kv/services/codex-review-app` | `scripts/seed-codex-review-app.sh <pem>` | `~/.config/codex-review/`, `0400` |
| The `codex` Plane user's API token | `kv/services/codex-plane` | `scripts/seed-codex-plane-token.sh`, which reads the clipboard | `~/.config/plane/api_key`, `0400` |

Each seed script checks the credential before it writes. The App script requires the exact
permission set and an install on all repositories. The Plane script requires the `codex`
user's email and a token that is not Pedro's. To deliver both, run:

```bash
./scripts/deploy-codex-248.sh
```

The play mints a GitHub token and reads `PET-553` as `codex`, so a bad identity fails the
run. A plain `ansible-playbook` run carries no identity and leaves both files as they are.

Without `contents:write`, the App's review never counts toward branch protection, and it
cannot push. `codex-gh` also refuses an approval and a merge.

## Review a pull request

Every run starts with `codex-quota`. As `codex`, in `~/work`:

```bash
codex-quota && codex exec "Review PeteDio-Labs/petedio-iac#<n> for PET-<n>."
```

The run uses these tools, which `AGENTS.md` describes:

| Tool | What it does |
|---|---|
| `codex-gh` | Runs `gh` with a 1-hour installation token. `pr view`, `pr diff`, `pr checks` and `pr review --comment` |
| `git` | Fetches over HTTPS with a read-only token narrowed to one repository, through `/etc/gitconfig` |
| `plane get PET-<n>` | Prints the item, its state, its description and its comments |
| `plane comment PET-<n> < body.html` | Posts HTML as `codex`, then reads it back |

## Run a review

The role installs the `petedio-review` skill to `~/.codex/skills/petedio-review/`. It posts
a comment review through `codex-gh` and a summary on each PET item the PR names, through
`plane`. It never approves and never runs the PR's code. Pedro chose its rules on
2026-10-01, and Codex revised the wording for its own use.

To review a pull request, connect as `codex`, then run:

```bash
codex-review <repo> <n>
```

For example, `codex-review petedio-iac 406`. To raise the effort, add `high` as a third
argument. Use `high` when Pedro asks, or when the diff touches a sensitive path such as a
workflow, `CODEOWNERS`, sudoers, a Vault policy or a GitHub App.

`codex-review` does what a review needs, in order:

1. **Takes a lock.** Every review spends the same Plus allowance, so reviews run one at a
   time. A second caller waits up to `codex_review_lock_wait_s` seconds, then exits 3.
2. **Reads the pull request's state.** A missing or closed pull request exits 2 before
   any allowance is spent. A merged one still runs, because the skill can review it. The
   check runs after the lock, because a pull request can close during the wait.
3. **Runs `codex-quota`** after it holds the lock, so each run reads the allowance after
   the previous run spent its share. It puts the output in the prompt, because
   `AGENTS.md` stops a run without it.
4. **Starts `codex exec` in `~/work`.** The sandbox writes only under the run's working
   directory, so a run started elsewhere cannot clone into `~/work`.
5. **Keeps each run's files apart.** The prompt, log and final message go to
   `~/work/reviews/runs/`, with a timestamp in each name.

It exits 0 when the run finishes, 1 when `codex-quota` refuses or the run fails, 2 on a
usage error, an unreadable allowance or a missing or closed pull request, and 3 on a lock
timeout.

## Upgrade Codex

Change `codex_version` and `codex_sha256` together in `defaults/main.yml`. Then read
`codex debug models` on the host: a retired `codex_model` fails every run. The digest is on
the release page, or:

```bash
gh release view rust-v<version> --repo openai/codex --json assets --jq '.assets[] | select(.name == "codex-package-x86_64-unknown-linux-musl.tar.gz") | .digest'
```
