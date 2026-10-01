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

## The boundaries, and where each lives

| Boundary | Where | Who can change it |
|---|---|---|
| No route to `192.168.0.0/16`, the tailnet or other private ranges | Guest firewall, `codex.tf` | A merged Terraform change |
| No `danger-full-access` sandbox | `/etc/codex/requirements.toml`, root-owned | Root on the host |
| No merge, no workflow edits, `codex/*` branches only | The worker's GitHub App and ruleset | Pedro, in GitHub |
| What the worker is told | `~/.codex/AGENTS.md` | The session user. It is guidance, not a boundary |

## Bring the host up

1. Merge the Terraform change. The apply creates CT 248 and its firewall rules.
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

Codex runs each command inside bubblewrap, which needs user namespaces inside this
unprivileged container. To check that the sandbox works, and that it holds, run these as
`codex` after the sign-in:

```bash
cd ~/work && codex exec 'Run `touch ~/outside.txt` and report whether it succeeded.'
```

The write outside the working directory must fail. To check the requirements file, ask for
the mode it forbids:

```bash
cd ~/work && codex exec --sandbox danger-full-access 'Print the sandbox mode you run under.'
```

Codex prints a warning that the value is disallowed by requirements, and falls back to an
allowed mode.

## Upgrade Codex

Change `codex_version` and `codex_sha256` together in `defaults/main.yml`. The digest is on
the release page, or:

```bash
gh release view rust-v<version> --repo openai/codex --json assets --jq '.assets[] | select(.name == "codex-x86_64-unknown-linux-musl.tar.gz") | .digest'
```
