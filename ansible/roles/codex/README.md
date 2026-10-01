# codex role (PET-553)

Installs the Codex CLI on `codex-248` and leaves it ready for unattended runs
(`codex exec`), once a person signs it in to OpenAI. The host is the worker for the
`PET-549` proof of concept: Codex implements on `codex/*` branches, and a Claude session
and Pedro review before anything merges.

| | |
|---|---|
| Host | `codex-248`: `192.168.50.248`, VMID 248, pve03 |
| Terraform | `environments/homelab/codex.tf`, which also declares the guest firewall |
| Playbooks | `playbooks/configure-pve-firewall.yml` once, then `playbooks/configure-codex.yml` |
| Runs as | `codex`, a non-root user with no sudo |
| Codex | pinned by `codex_version` and `codex_sha256` in `defaults/main.yml` |
| Container features | `nesting=1` only, declared in `roles/lxc-features` |

## The boundaries, and where each lives

| Boundary | Where | Who can change it |
|---|---|---|
| No route to `192.168.0.0/16`, the tailnet or other private ranges | Guest firewall, `codex.tf` | A merged Terraform change |
| No `danger-full-access` sandbox | `/etc/codex/requirements.toml`, root-owned | Root on the host |
| No merge, no workflow edits, `codex/*` branches only | The worker's GitHub App and ruleset | Pedro, in GitHub |
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

## Upgrade Codex

Change `codex_version` and `codex_sha256` together in `defaults/main.yml`. Then read
`codex debug models` on the host: a retired `codex_model` fails every run. The digest is on
the release page, or:

```bash
gh release view rust-v<version> --repo openai/codex --json assets --jq '.assets[] | select(.name == "codex-package-x86_64-unknown-linux-musl.tar.gz") | .digest'
```
