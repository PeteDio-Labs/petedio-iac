# claude-code role (PET-396)

Installs Claude Code on `claude-247` and leaves it serving Remote Control sessions, so a
session running on that LXC is drivable from `claude.ai/code` or the Claude phone app.

Remote Control is not a cloud runtime: the session runs on this host, against this
filesystem, and the web and mobile clients are a window onto it. That is the point of the
box — a session here keeps its working tree and its place in a task when your laptop
closes.

| | |
|---|---|
| Host | `claude-247` — `192.168.50.247`, VMID 247, pve03 |
| Terraform | `environments/homelab/claude.tf` |
| Playbook | `ansible/playbooks/configure-claude-code.yml` |
| Runs as | `claude`, a non-root user with **no sudo at all** |
| Deploy | `gh workflow run ansible-claude-247.yml --ref main`; fallback `scripts/deploy-claude-247.sh` (PET-515) |
| Serves | one `claude remote-control` server per entry in `claude_remote_sessions`, plus the work-loop timer when `claude_loop_enable` is set |

## What Ansible cannot do, and why

Remote Control requires signing in to a claude.ai account on a Pro, Max, Team or
Enterprise plan. **API keys and long-lived `claude setup-token` tokens are refused** — the
feature does not accept them, so there is no unattended path to an eligible login.

`gh` is a different case. It would accept a token, and that is the reason this host must not
give it one. For the route a private clone takes instead, see "The private workspace repo"
below.

So this role installs, configures and renders the units, and starts them only once the
operator steps are done. `claude_remote_enable` defaults to `false`, so a host nobody has
bootstrapped gets stopped units. claude-247 declares `true` in
`inventory/host_vars/claude-247.yml`, and even then the role refuses to start a unit until
the one-time consent is on disk: a server started without it waits at its prompt forever
while systemd reports it active (PET-431).

## Deploying

The primary path is the `ansible-claude-247.yml` workflow on the homelab runner (PET-515).
Dispatch it from a machine whose `gh` holds the `workflow` scope:

```sh
gh workflow run ansible-claude-247.yml --ref main
```

It reads 247's identities through the `claude-247-deploy` JWT role, which only that workflow,
dispatched on `main`, can mint. `scripts/deploy-claude-247.sh` is the fallback: it reads the
same fields through the `ansible` AppRole from the operator's machine. Both paths hand the
fields to `scripts/claude-247-extra-vars.sh`, so they run the same checks, refuse the same
mix-ups and write the same extra-vars.

The workflow has no loop input. Turning the loop timer on or off still goes through the
script, with `-e claude_loop_enable=true` or `false`. The steps below name the script; the
workflow lands the same identities wherever a step runs a plain deploy.

A dispatch always leaves claude-loop.timer stopped and disabled, because the workflow has no
loop input. If you had enabled the loop with the script, run
`./scripts/deploy-claude-247.sh -e claude_loop_enable=true` again after the dispatch.

## Bootstrap

Run steps 2 onward from this repo's `ansible/` directory. Terraform creates the container
on merge; nothing here needs a node-side step, because nothing here runs Docker.

1. **Create the LXC.** Merge `claude.tf`, or apply it locally. There is no
   `scripts/lxc-features-247.sh` to run — this host needs no `features{}`.

2. **Install everything.** The units land stopped:

   ```sh
   ansible-playbook playbooks/configure-claude-code.yml
   ```

3. **Sign in.** As the session user, from a project directory. The trust dialog never saves
   trust for a home directory, so starting anywhere else leaves Remote Control refusing to
   run later:

   ```sh
   ssh claude@192.168.50.247
   cd ~/work/petedio/iac && claude
   ```

   Accept the workspace trust dialog, then run `/login` and pick the claude.ai account.
   The flow prints a URL — open it in a browser on any machine and paste the code back.
   Exit with `/exit`.

4. **Accept Remote Control once.** The first run explains the feature and asks
   `Enable Remote Control? (y/n)`. Answer `y`, confirm it prints a session URL, then stop it
   with Ctrl+C:

   ```sh
   claude remote-control
   ```

   ⚠ **Do not skip this step, and do not leave it to the unit.** The answer lands in
   `~/.claude.json` as `remoteDialogSeen: true`. A unit cannot answer — its stdin is
   `/dev/null` — so without it the server waits at the prompt forever while `systemctl`
   reports it active. claude-247 spent 15 hours of 2026-09-12 like that (PET-431). Using
   Remote Control from an interactive `claude` session does not record it either: one served
   on claude-247 for two days and left no `remoteDialogSeen` behind.

5. **Hand it to systemd.** Declare `claude_remote_enable: true` in
   `inventory/host_vars/<host>.yml` — claude-247 already does — and run the play:

   ```sh
   ansible-playbook playbooks/configure-claude-code.yml
   ```

   The play checks for the consent before it starts anything. Without it, the play converges
   everything else, leaves the units alone, and fails at the end with the steps above.
   ⚠ Do not pass `-e claude_remote_enable=true` instead: the next run without the flag stops
   the server, which is how a loop deploy took claude-247's down.

6. **Optional — deliver the private workspace repo.** Declare
   `claude_workspace_mirror_enable: true` in the host's `host_vars`, then:

   ```sh
   ./scripts/seed-workspace-mirror-vault.sh ~/Downloads/petedio-workspace-mirror.*.pem
   ./scripts/deploy-claude-247.sh
   ```

   One run mirrors the repo and clones the session's copy; there is no second pass. Then take
   the one step no play can take, because the dialog is interactive:

   ```sh
   ssh claude@192.168.50.247
   cd ~/work/petedio/workspace && claude    # accept the trust dialog, then /exit
   ```

   Until that dialog is accepted, the play does not start that directory's unit, and it fails
   at the end naming the directory (PET-499). A server started there exits at once with
   `Error: Workspace not trusted`, and five starts in 5 minutes land its unit in `failed`.
   That is the opposite of the consent in step 4, which waits at its prompt while systemd
   reports the unit active (PET-431). After the dialog, re-run `./scripts/deploy-claude-247.sh`.
   PET-481 confirmed the sequence on the machine. See "The private workspace repo" below.

   > ⚠ **Do not paste a deploy key.** Step 6 said to, until PET-493. PeteDio-Labs disallows
   > deploy keys for every repository it owns — `gh api orgs/PeteDio-Labs --jq
   > .deploy_keys_enabled_for_repositories` is `false`, and the repository's key page reads
   > "Disabled by PeteDio-Labs". A key generated here is one GitHub will refuse.

   > ⚠ **Do not run `gh auth login` on this host.** Step 6 said to, until PET-480.
   > `vault/Claude/claude-247.md` forbids it by name: the OAuth token it writes to
   > `~/.config/gh/hosts.yml` carries Pedro's permissions, under the same user every session
   > runs as. For `petedio-iac` and `petedio-workspace`, a session here does not push and does
   > not open pull requests — it writes a branch, and the Mac bundles and pushes it. Step 7
   > below is the single exception, and it is one repository wide.

7. **Optional — deliver the vault, which a session can push to.** Declare
   `claude_vault_enable: true` in the host's `host_vars`, then seed a **third** App and
   deploy:

   ```sh
   ./scripts/seed-claude-vault-app.sh --app-id <id> --installation-id <id> --shred ~/Downloads/petedio-vault-247.*.pem
   ./scripts/deploy-claude-247.sh
   ```

   Then accept the trust dialog in that directory too:

   ```sh
   ssh claude@192.168.50.247
   cd ~/work/petedio/vault && claude        # accept the trust dialog, then /exit
   ```

   ⚠ **This is the one outbound write credential on the host a session can read**, and the
   shape is deliberately inverted from step 6 — root fetches the mirror, but the *session* is
   what pushes a vault note. Read "The vault, and the one writable key" below before you run
   it. Creating the App and generating its key are Pedro's steps, not a session's.

## The private workspace repo (PET-480, re-routed by PET-493)

`petedio-workspace` is private, so nothing clones it without a credential, and the login that
would supply one is forbidden here. Pedro chose a **read-only deploy key** on 2026-09-17, as
an explicit override of the rule that keeps every credential off this host.

**That route could never have worked, and the reason is outside this role.** PeteDio-Labs
disallows deploy keys for every repository it owns:

```sh
gh api orgs/PeteDio-Labs --jq .deploy_keys_enabled_for_repositories   # false
```

The repository's key page reads "Disabled by PeteDio-Labs". PET-481 ran the two-step flow to
completion and generated a key on 247 that GitHub would have refused, which is why the
delivery never started. PET-493 replaced the key with a **GitHub App**, `petedio-workspace-mirror`,
Contents and Metadata read-only, installed on that one repository. Do not go back to a key to
make a red run green.

**The override stays narrow, and the shape is what makes it narrow.** The forbidden act writes
a token carrying Pedro's permissions across every repo he can reach, write included. An App
installed on one repository, read-only, cannot push, cannot read a second repository, and
cannot act as him — the same three properties the deploy key was chosen for. Blast radius was
the objection, not the presence of a secret.

⚠ **Both halves of that argument are checked, not assumed.**
`scripts/seed-workspace-mirror-vault.sh` refuses to write the credential unless GitHub reports
`repository_selection: selected`, permissions of exactly `contents=read,metadata=read`, and —
asked with the App's own key — exactly one reachable repository. Widen the App and the next
seed fails.

⚠ **This is not the loop's App, and must not become it.** The loop's App carries
`contents:write` and `pull_requests:write`, because it opens draft PRs. Pointing the mirror at
`kv/services/claude-loop` would hand a half-hourly root timer a push credential for
`petedio-iac`. Two Apps, two Vault paths, two directories, two brokers —
`scripts/claude-247-extra-vars.sh`, which both deploy paths run, and the seed script both
refuse by App id.

**No session holds anything.** Four properties carry that:

| | |
|---|---|
| The key is `0400 root:root` and the broker is `0500 root:root` | Sessions run as `claude` with no sudo (PET-408), so a session can neither read the key nor mint a token. `/etc/claude-loop` already works this way. |
| No token is ever written down | `claude-workspace-mirror-broker` mints one per fetch and hands it to `git` as a credential helper, over a pipe. It reaches no file, no git config and no command line. |
| Root fetches into a bare mirror it owns | `/var/lib/claude-workspace-mirror/petedio-workspace.git`, refreshed by `claude-workspace-mirror.timer`. The session's working clone is cloned from that mirror over a local path. |
| The clone uses `git -c … clone`, never `git clone -c …` | The second form persists the helper into the new repository's config; the first does not. Measured on git 2.50.1. The mirror's config names no helper at all. |

⚠ **The mirror is the security boundary, not an extra hop.** The obvious shape — point the
`claude`-owned clone at GitHub and let a root timer fetch it — hands root a `git` process
running inside a directory the sessions own. `git` honours `core.sshCommand`, `core.hooksPath`
and `core.fsmonitor` from the repository's own config, so a session that rewrites its clone's
`.git/config` gets code execution as root on the next fetch. Root must never run `git` inside
a path a session can write.

⚠ **Every git command that uses the broker resets the helper list first.**
`claude_workspace_mirror_git_opts` leads with an empty `-c credential.helper=`, and the empty
value is load-bearing: `credential.helper` is multi-valued, so a later `-c
credential.helper=<broker>` *appends* to whatever `/etc/gitconfig` and root's `~/.gitconfig`
already configure. Measured on git 2.50.1, a machine with a stored credential answered first
and the broker was never run — so its host and path checks silently stopped applying. Use the
variable rather than writing the flags out again.

**`origin` in the session's clone is the local mirror, not GitHub.** A session fetches from the
mirror. With `claude_code_push_enable`, it pushes to GitHub through `remote.origin.pushurl` and
the code-push broker. See "Code push and pull requests (PET-507)". Before PET-507, this paragraph
said a session "can commit and cannot push". Nothing updates that clone on a schedule either: a
session pulls its own repo, like any developer.

**One step is interactive and no play can take it.** Claude Code refuses to work in a
directory nobody has trusted, so after the first delivery: `ssh claude@192.168.50.247`, then
`cd ~/work/petedio/workspace && claude`, accept the dialog, `/exit`.

### Rotating the App key

Generate a new private key on the App's settings page, then re-seed and re-deploy:

```sh
./scripts/seed-workspace-mirror-vault.sh --shred ~/Downloads/petedio-workspace-mirror.*.pem
./scripts/deploy-claude-247.sh
```

Delete the old key on the settings page afterwards. Nothing on 247 caches a token, so the
next timer firing uses the new key with no further step. To check a delivery that has started
failing, run the broker by hand as root on the host — it prints a token, so read the exit
status and not the output:

```sh
/usr/local/sbin/claude-workspace-mirror-broker mint-token >/dev/null && echo "mint ok"
systemctl start claude-workspace-mirror.service && systemctl status claude-workspace-mirror.service
```

A mint that works and a fetch that does not means the App lost access to the repository.

## The vault, and the one writable key (PET-498)

`petedio-vault` is private, and a session here does something no other delivery in this role
does: it **pushes**. Pedro approved writing to `main` directly. That branch carries no
protection, and the Obsidian Git plugin already auto-commits and pushes to it every 10 minutes
from the Mac, so a session committing a note joins a branch that has a second writer.

**Set `claude_vault_enable: true` in host_vars, never with `-e`.** Same reason as
`claude_remote_enable`: the default is `false`, so the next run without the flag would stop
delivering. `inventory/host_vars/claude-247.yml` declares it.

**Read the shape before you copy it from the mirror above, because it is inverted.**

| | the workspace mirror | the vault |
|---|---|---|
| Who uses the credential | root, on a timer | the session |
| Key | `0400 root` in `/etc/claude-workspace-mirror/` | `0400 claude` in `~/.config/claude-vault/` |
| Broker | `0500 root` | `0500 claude:claude` |
| Session's `origin` | a local bare path — pushing is impossible | `https://github.com/PeteDio-Labs/petedio-vault.git` |
| App permissions | Contents and Metadata **read** | `contents:write`, `metadata:read` |

The mirror can keep its key away from the session because root is what fetches. Here the
session is what pushes, so the session has to reach the key. ⚠ **Every process running as
`claude` on this host can therefore push to the vault**, the work loop's `claude -p` included
if `claude_loop_enable` is ever set. Read that as the price of the feature. A stricter file
mode would be locking out the user the design hands the key to.

**What bounds it is the App.** One installed repository, `contents:write` and `metadata:read`,
nothing else. It cannot open a pull request, cannot read a second repository, and cannot act
as Pedro. That holds while the installation stays as seeded, and the installation is changed
in the GitHub UI, where nothing in this repo notices.

### Seeding it

⚠ **A third App, not the loop's and not the mirror's.** Three Apps, three Vault paths, three
directories, three brokers. Creating a GitHub App and generating its key are Pedro's steps,
not a session's (`vault/Claude/README.md`).

1. Create the App under `PeteDio-Labs`, named `petedio-vault-247`, with `contents: write` and
   `metadata: read`, webhook off, private to the org.
2. Install it on **`PeteDio-Labs/petedio-vault` alone** — not "All repositories".
3. Generate a private key, and note the App ID and the Installation ID.
4. Seed and deploy:

```sh
./scripts/seed-claude-vault-app.sh --app-id <id> --installation-id <id> --shred ~/Downloads/petedio-vault-247.*.pem
./scripts/deploy-claude-247.sh
```

`seed-claude-vault-app.sh` refuses to write the credential unless GitHub itself reports
`repository_selection: selected`, exactly one reachable repository and it is `petedio-vault`,
permissions equal to `contents=write,metadata=read`, and an App id matching neither of the
other two. It checks with a JWT signed by the App's own key, so a `gh` token that happens to
be more privileged cannot make a wrong App look right.

**One step is interactive and no play can take it**, the same one the workspace repo needs,
in its own directory: `ssh claude@192.168.50.247`, then `cd ~/work/petedio/vault && claude`,
accept the dialog, `/exit`.

**The session entry is `spawn: same-dir`, not `worktree`.** `git worktree add` refuses a
branch that is already checked out — `fatal: 'main' is already used by worktree at ...` — and
this clone sits on `main` because pushing a note to `main` is the point. Concurrent sessions
in that directory can collide; that is the documented trade for `same-dir`.

### Rotating the vault App key

Generate a new private key on the App's settings page, then re-seed and re-deploy with the
commands above. Delete the old key on the settings page afterwards. Nothing on 247 caches a
token. To check a delivery that has started failing, run the broker by hand **as the session
user** — it prints a token, so read the exit status and not the output:

```sh
runuser -u claude -- /home/claude/.local/bin/claude-vault-broker mint-token >/dev/null && echo "mint ok"
runuser -u claude -- git -C /home/claude/work/petedio/vault ls-remote origin >/dev/null && echo "reaches the repo"
```

A mint that works and an `ls-remote` that does not means the App is not installed on
`petedio-vault`. ⚠ **To revoke this access, uninstall the App or delete its key on GitHub.**
Removing the clone from 247 does not revoke anything.

## Code push and pull requests (PET-507)

A session here pushes branches to `petedio-iac`, `petedio-media-iac` and `petedio-workspace`,
and opens pull requests on them. So 247 implements work itself instead of handing a bundle to
the Mac. It never merges. On `petedio-iac` and `petedio-media-iac`, `main` requires a review
the App cannot give. On `petedio-workspace`, only the session rule stops a merge.

**Set `claude_code_push_enable: true` in host_vars, never with `-e`**, for the reason the vault
section gives. `inventory/host_vars/claude-247.yml` declares it.

**The shape is the vault's, widened to three repositories.** The key is `0400 claude` in
`~/.config/claude-code-push/`, behind a `0500 claude:claude` broker that refuses root. Every
process running as `claude` can therefore push to those three repositories and open pull
requests on them. The vault section's "the one writable key" no longer holds: this is a second.

**What bounds it is the App, branch protection on two repositories, and the session rule:**

- `contents:write`, `pull_requests:write` and `metadata:read`, installed on the three
  repositories alone.
- No `workflows` permission, so GitHub refuses a push that touches `.github/workflows/**`.
- `main` on `petedio-iac` and `petedio-media-iac` requires one approving review, with required
  checks and `strict` on. The App cannot give that review, so Pedro decides every merge there.
- `petedio-workspace` cannot carry branch protection on the org's plan: GitHub answers HTTP 403
  for both branch protection and rulesets. On that repository the session rule is the only
  guard: a session opens a pull request, and never merges or pushes to `main`. The App's
  `contents:write` permission would accept a push to `main` there.

**The broker narrows every git credential to one repository.** git asks with the repository
path, because the play sets `credential.useHttpPath=true` in each clone. The broker refuses a
request without a path, checks the name against its allow-list, and mints a token scoped to
that repository alone.

**The clones keep their origins.** `iac` and `media-iac` fetch from GitHub and push through
the broker. The workspace clone fetches from the root-owned mirror, so the play gives it a
GitHub push URL (`remote.origin.pushurl`). Its fetches stay on the mirror. The play also sets
`user.name` and `user.email` to `claude-247`, so commits name the host, not Pedro.

### Opening a pull request

To run `gh`, call the wrapper by its full path, because `~/.local/bin` is not on the Remote
Control units' `PATH`:

```sh
git push -u origin pet-<n>-<slug>
~/.local/bin/claude-gh pr create --draft --fill
```

`claude-gh` mints a token per command and passes it to `gh` in `GH_TOKEN`. Nothing logs in,
and it refuses `gh auth` except `gh auth status`. In the workspace clone, `gh` cannot read a
repository from a local fetch URL, so the wrapper sets `GH_REPO` from the push URL. It also
adds `--head <branch>` to `pr create`, because `gh` 2.90.0 fails there with "could not resolve
remote origin" otherwise.

⚠ **Actions logs and check runs on the private workspace repository need permissions this App
lacks** (`actions:read`, `checks:read`). `gh run view --log` there fails with a 403 or a 404.

### Seeding it

Creating the App and generating its key are Pedro's steps, not a session's.

1. Create the App under `PeteDio-Labs`, named `petedio-code-247`, private to the org, with the
   webhook off.
2. Set **Repository permissions** to `Contents: Read and write`, `Pull requests: Read and
   write` and `Metadata: Read-only`. Grant nothing else, and never `Workflows`.
3. Install it on **Only select repositories**: `petedio-iac`, `petedio-media-iac` and
   `petedio-workspace`.
4. Generate a private key. Then seed and deploy from `~/petedio/iac`:

```sh
./scripts/seed-claude-code-app.sh --shred ~/Downloads/petedio-code-247.*.private-key.pem
./scripts/deploy-claude-247.sh
```

`seed-claude-code-app.sh` finds the ids through `gh`, or reads `APP_ID` and `INSTALLATION_ID`
from the environment. It refuses to write unless GitHub reports `repository_selection:
selected`, exactly those three repositories, permissions equal to
`contents=write,metadata=read,pull_requests=write`, and an App id that matches none of the
other three Apps on 247.

### Rotating the code-push App key

Generate a new key on the App's settings page, then re-seed and re-deploy with the commands
above. Delete the old key afterwards. To check a delivery that has started failing, run the
broker as the session user. It prints a token, so read the exit status, not the output:

```sh
runuser -u claude -- /home/claude/.local/bin/claude-code-push-broker mint-token petedio-iac >/dev/null && echo "mint ok"
```

A mint that fails for one repository name and works for another means the App is not
installed on the first. ⚠ **To revoke this access, uninstall the App or delete its key on
GitHub.** Removing the clones from 247 revokes nothing.

## The IaC toolchain (PET-508)

`claude_iac_tools_enable: true` installs `terraform`, `ansible-core`, `ansible-lint` and
`shellcheck` at the versions CI pins, so a session here can verify the IaC it writes. The
tools are root-owned under `/opt/claude-iac-tools` and linked into `/usr/local/bin`, so a
session runs them but cannot replace them. `tasks/iac-tools.yml` carries the design, and
`tests/claude-iac-tools-pins.yml` fails CI when the role's pins drift from the workflows'.

The play does not install the Galaxy collections. To lint the tree the way CI does, run this
once as `claude` from `ansible/`, which installs them under `~/.ansible/collections`:

```bash
ansible-galaxy collection install -r requirements.yml
```

Matching pins are not a matching verdict. To trust a lint run here, compare its `Passed:`
line with the `ansible-validate` run on the same commit.

## The read-only Proxmox token (PET-510)

A session here reads the Proxmox API as `claude-247@pve!audit`. So 247 checks guest state,
storage and task logs itself instead of asking the Mac. The token changes nothing: Proxmox
refuses every write it sends.

**Set `claude_pve_audit_enable: true` in host_vars, never with `-e`**, for the reason the vault
section gives. `inventory/host_vars/claude-247.yml` declares it.

**The shape is the vault's, read-only.** The token is `0400 claude` in `~/.config/claude-pve/`,
beside the cluster CA at `0444`. Every process running as `claude` can therefore read the
whole cluster's configuration through it, including the work loop's `claude -p` if
`claude_loop_enable` is ever set.

**What bounds it is Proxmox, not the wrapper:**

- The user `claude-247@pve` holds `PVEAuditor` on `/`. It has no password, so it cannot log in
  to the web UI.
- The token has privilege separation on and its own `PVEAuditor` ACL on `/`. Its privileges are
  the intersection of its ACL and its user's, so a grant to either one alone widens nothing.
- `PVEAuditor` holds only `.Audit` privileges. It reads configuration and status, and it
  cannot start, stop, create, change or delete anything.

**`pve-get` is GET only.** It refuses `-X` with any other method, pins `ca.pem`, and prints the
response body. It connects to `192.168.50.11` and checks the leaf certificate against that IP,
because 247 resolves neither `pve02` nor `pve02.lab`. It clears Python's `VERIFY_X509_STRICT`
flag, because the PVE root CA has no key-usage extension and Python 3.13 refuses it otherwise.
The wrapper protects against a typo, not
against a session: a process that reads `token.env` can send a POST, and Proxmox answers 403.

### Reading the API

Call the wrapper by its full path, because `~/.local/bin` is not on the Remote Control units'
`PATH`. The path is relative to `/api2/json`:

```sh
~/.local/bin/pve-get /cluster/resources
~/.local/bin/pve-get /nodes/pve02/qemu
~/.local/bin/pve-get '/nodes/pve02/tasks?limit=20'
```

### Minting it

Terraform declares none of this. The CI token cannot create a user or an ACL, and widening it
to do so is refused. `playbooks/mint-claude-247-pve.yml` does it instead, once, from the Mac,
as `root@pam` over the `pve02` SSH alias. It needs a Vault token, which it reads from
`VAULT_TOKEN`, then the Keychain item `vault-root-token`, then a prompt.

Minting is Pedro's step. Pedro runs the playbook, or a Mac session runs it after Pedro types
his authorization in that session's own chat. A peer's relay is not that authorization. From
`~/petedio/iac/ansible`, then from `~/petedio/iac`:

```sh
ansible-playbook playbooks/mint-claude-247-pve.yml
./scripts/deploy-claude-247.sh
```

The playbook creates the user and its ACL, mints the token with privilege separation, grants
the token's ACL, and writes `kv/services/claude-247-pve` with `token_id`, `secret`, `endpoint`
and `ca_pem`. Proxmox shows the secret once, so the play never logs it and never mints twice:

| The token on pve02 | The Vault entry | The play |
|---|---|---|
| absent | any | mints it and writes the entry |
| present | holds `token_id` and `secret` | changes nothing |
| present | lacks either field | refuses, and names the repair |

### Proving it

Run the first two as `claude` on 247, and the third on the Mac.

1. `~/.local/bin/pve-get /access/permissions` lists `/` with `.Audit` privileges only, such as
   `Sys.Audit`, `VM.Audit` and `Datastore.Audit`.
2. A POST with the token returns `403`. `pve-get` cannot send one, so this reads `token.env`
   in Python without printing it:

   ```sh
   python3 -c 'import http.client,ssl;d="/home/claude/.config/claude-pve/";e=dict(l.strip().split("=",1) for l in open(d+"token.env") if "=" in l and not l.startswith("#"));x=ssl.create_default_context(cafile=d+"ca.pem");x.verify_flags&=~ssl.VERIFY_X509_STRICT;c=http.client.HTTPSConnection("192.168.50.11",8006,context=x);c.request("POST","/api2/json/nodes/pve02/apt/update",headers={"Authorization":"PVEAPIToken=%s=%s"%(e["PVE_TOKEN_ID"],e["PVE_TOKEN_SECRET"])});print(c.getresponse().status)'
   ```

3. `ssh pve02 pveum user token permissions claude-247@pve audit` lists `.Audit` privileges on
   `/` and nothing else.

### Rotating the token

To rotate it, remove the token on pve02, then mint and deploy again with the commands above:

```sh
ssh pve02 pveum user token remove claude-247@pve audit
```

The play writes a new version of `kv/services/claude-247-pve`. KV v2 keeps the old version,
which names a token that no longer exists.

⚠ **To revoke this access, remove the token on pve02** with the command above. To remove the
user as well, run `ssh pve02 pveum user delete claude-247@pve`. Deleting
`~/.config/claude-pve/` on 247 revokes nothing, and the next deploy lands it again.

## Verify

A unit that is `active` is not a server that registered: one waiting at the consent prompt is
`active` too. `scripts/lab-verify.sh` passes a server only when its own cgroup holds
established outbound HTTPS — on claude-247 on 2026-09-14, 18 or 19 connections in the first
minute and a steady 3 or 4 after — and fails one whose current start logged the consent
dialog or the login error.

To check by hand, read the start of the current run, not the tail of the unit's journal:

```sh
systemctl status claude-remote-iac
journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value claude-remote-iac) -o cat | head -20
```

A serving start logs `Connecting · petedio-iac · <branch>`, a `Connected` status line,
`Capacity: 0/32` and a `https://claude.ai/code?environment=…` URL. For its first few minutes
the server also redraws that status into the journal several times a second, with terminal
escape codes, so a tail taken then shows only redraws. After that it logs only events, such
as `Reconnected after 2s`.

⚠ `<branch>` is whatever the clone at `~/work/petedio/iac` has checked out. Sessions start
their worktrees from it, so a clone parked on an old branch serves every session that
branch.

The session then appears in the list at `claude.ai/code`, named `iac-<something>`. Opening
it from a phone and asking for `pwd` is the check that proves the whole path end to end.

## If the unit will not stay up

Read the journal first — the server names its own reason:

```sh
journalctl -u claude-remote-iac -n 100 --no-pager
```

Three causes account for most of it. **No eligible login**: the server exits at once, which
is what `claude_remote_enable: false` exists to prevent before step 3. **A telemetry
opt-out** in the environment — see the warning in `tasks/main.yml`; the symptom is the
feature reporting itself unavailable. **Untrusted workspace**: the journal reads
``Error: Workspace not trusted. Please run `claude` in <dir> first``, and the server exits 1.
Nobody accepted the trust dialog in that unit's directory, or it was accepted somewhere else.
Between retries `systemctl is-active` says `activating`, which reads like a slow start. The
fifth start in 5 minutes parks the unit in `failed`, and accepting the dialog later does not
restart it. The play reads the trust before it starts a unit, so a deploy leaves an untrusted
unit stopped instead (PET-499). To recover, run `claude` in that directory as the session user,
accept the dialog, `/exit`, then re-run `./scripts/deploy-claude-247.sh`.

**If `systemctl start` answers `Start request repeated too quickly`,** the unit tripped the
`StartLimitBurst` in its `[Unit]` section and is parked in `failed`. Clear it with
`systemctl reset-failed claude-remote-<name>`, then start it. The play does this for you
before starting, so a re-run is not blocked by the wreckage of the run before it.

## If the unit stays up and serves nothing

Suspect the one-time consent first. A server that never had its `y` prints the feature's
introduction — *"Take this session with you… The session keeps running on this machine…"* —
and then waits on stdin, which systemd points at `/dev/null`. It stays `active`, holds no
connection, and never logs the prompt it waits at. The prompt has no newline, so journald
holds it until the process stops and stamps it with the **stop** time, marked
`_LINE_BREAK=eof`. Two diagnoses read that line as a shutdown message (PET-427, PET-431).

```sh
jq '.remoteDialogSeen' /home/claude/.claude.json   # must print true
```

To fix it, run bootstrap step 4 as the `claude` user, then
`systemctl restart claude-remote-iac`. The unit needs no terminal after that. An earlier
version of this README offered a detached `tmux` session as the fallback for a server that
"wants a terminal"; the terminal was only ever wanted for this one answer.

## Operating it

**Add a project.** Append to `claude_remote_sessions` and re-run the play. Each entry gets
its own unit, so one project's crash leaves the others serving. `spawn: worktree` gives
each on-demand session its own git worktree; `same-dir` shares the directory and lets
concurrent sessions collide.

**An entry whose directory is missing gets no unit, and everything else still converges.**
The play then fails at the end naming the directory and the clone step. That order matters:
until PET-466 the check was an assert in the middle of the role, so one entry pointing at a
directory nobody had cloned stopped the play before *any* unit was rendered — and because
the units already running keep answering, the host looked fine while the role quietly
stopped converging. Clone the directory or drop the entry; a red play with every other
session updated is the intended state in between.

**Restarting drops connections.** The handler here reloads systemd but never restarts a
running server, because a restart disconnects whoever is using it. Restart deliberately:
`systemctl restart claude-remote-iac`. Sessions the server was serving can be brought back
for about four hours afterwards.

**Repos are seeded, never updated.** The clone task carries a `creates:` guard, so a repo
that is already there is left alone: a re-run that fast-forwarded every repo would move a
branch out from under a session mid-task. The session pulls its own repos, like any
developer.

**Claude Code updates itself.** The npm prefix is per-user (`~/.npm-global`) so the
auto-update can write to it. The play installs the binary only when it is missing; the
version it runs is the tool's business, not Ansible's.

## The permission mode, on the record

Sessions start in `auto` (`claude_permission_mode`), since PET-433. Claude Code approves
routine actions itself and asks only for risky ones, and Remote Control carries that question
to the Claude app. Work you drive from a phone keeps moving, which is why PET-396 first chose
`bypassPermissions`.

**The mode also decides whether sessions can message each other.** With
`crossSessionInbound` unset, Claude Code delivers `SendMessage` only between sessions of the
same permission-mode class, and holds any other for approval while the sender sees
`success`. Under `bypassPermissions`, every message between a 247 session and the prompting
Mac session was held (PET-431). `auto` is in the prompting class.

Two things keep their own mode. The work loop's `claude -p` passes
`--permission-mode bypassPermissions` itself (`scripts/claude-loop-tick.sh`). And
`~/.claude/settings.json` is seeded once and never rewritten, so a `claude` you start by hand
over SSH keeps that file's `defaultMode`.

Be clear about what the host exposes whatever the mode. Claude Code's own guidance for
`bypassPermissions`, which the loop still uses, is "isolated containers and VMs only", and
**this container is not isolated from the lab** — it sits on the LAN with Vault, Proxmox and
Postgres. Until the work loop, the role provisioned no
outbound credential: the only key it placed was your *public* key, authorizing inbound SSH.
So a session reached what the LAN serves unauthenticated, plus whatever you added by hand
afterwards. ⚠ **`gh auth login` is the one addition that is forbidden outright**
(`vault/Claude/claude-247.md`): its OAuth token lands in `~/.config/gh/hosts.yml` under the
same user the sessions run as, and it carries Pedro's permissions across every repo he can
reach.

> ⚠ **Corrected 2026-09-22 (PET-498).** This section used to say the role provisioned no
> outbound credential for the sessions, and named the workspace mirror's App as the
> sanctioned counter-example precisely because a session could not read it. That is no longer
> the whole picture. Three sanctioned Apps now land here, and one of them is session-readable
> by design.

| App | Reaches | Key lives | A session can read it |
|---|---|---|---|
| the loop's | `petedio-iac`, push and pull requests | `/etc/claude-loop/`, `0400 root` | no — `0500 root` broker |
| the mirror's | `petedio-workspace`, read-only | `/etc/claude-workspace-mirror/`, `0400 root` | no — `0500 root` broker |
| the vault's | `petedio-vault`, `contents:write` | the session user's home, `0400 claude` | **yes, on purpose** |

The first two are read or used by **root**, so root can hold them. The vault's cannot work
that way: the thing that pushes a note **is** the session, so the session has to reach the
credential. Its broker is `0500 claude:claude` rather than `0500 root`, which keeps other
users out and cannot keep this user out — that user is the one the design hands the key to.

**So state the exposure plainly rather than implying a mode closes it.** Every process running
as `claude` on this host can push to `petedio-vault`, the loop's `claude -p` included if
`claude_loop_enable` is ever set. What bounds the damage is the App, not the file modes: one
installed repository, `contents:write` and `metadata:read`, no pull-request rights. It cannot
reach `petedio-iac`, cannot read a second repository, and cannot act as Pedro. Both halves of
that hold only while the installation stays as seeded, and it is changed in the GitHub UI,
where nothing in this repo notices. `scripts/seed-claude-vault-app.sh` re-checks the shape
against GitHub every time you run it.

⚠ **The work loop changes the picture again.** See "What the loop changes about the isolation
story" below before you set `claude_loop_enable`.

Deny rules apply in every mode. ⚠ But those deny rules live in
`~/.claude/settings.json`, which is owned by `claude` — the user the sessions run as — so a
session can rewrite them. To make them hold, put them in root-owned
`/etc/claude-code/managed-settings.json` instead. The same goes for `~/.bashrc` and
`~/.ssh/authorized_keys`: as seeded, a session can persist its own access.

Changing the mode is one variable, a play re-run, and `systemctl restart claude-remote-iac`.
The handler never restarts a running server, so it keeps the old mode until you restart it,
and the restart drops whoever is connected. For stricter prompting, set `default` (Manual)
or `acceptEdits`.

The session user is not root because the loop runs `bypassPermissions`, which Claude Code
refuses as root or under sudo on Linux.

## What the loop changes about the isolation story (PET-399)

`claude_loop_enable` puts a second thing on this host: a timer that takes one labelled
Plane work item, runs `claude -p` against it, and opens a **draft** pull request. Enabling
it gives the host an outbound credential for the first time, so the paragraph above is only
true while the loop is off.

**What lands, and where.** Two secrets go to `/etc/claude-loop/`, root-owned `0400`: the
Plane PAT that CI already uses, and a GitHub App private key with `contents: write` and
`pull_requests: write` on this repo. Neither is readable by `claude`.

**Why a broker and not an `EnvironmentFile`.** The repo's usual landing pattern — a
root-owned `0600` file handed to a unit through `EnvironmentFile=` — does not hold here.
systemd reads that file as root, but the values then sit in the process environment of a
process owned by `claude`, and a session in `bypassPermissions` can read
`/proc/<pid>/environ` for its own uid while a tick runs. So the secrets are reachable only
through `/usr/local/sbin/claude-loop-broker`, which is root-owned `0500` and exposes
exactly two subcommands: `next-item` and `mint-token`.

**There is no sudo on this host, and that is a correction (PET-408).** An earlier version
of this role installed `sudo` and an `/etc/sudoers.d/claude-loop` grant so that a tick
running as `claude` could call the broker. That was wrong, and it was wrong in a way worth
remembering: **sudo binds a grant to the UID, not to a process.** The tick and the
`claude -p` session it starts are the same user, so the session held the identical grant —
and the session's instructions come from a Plane work item. Anyone who could write one
could mint the token directly and skip every guard in the tick.

**So the privilege runs the other way now.** `claude-loop.service` runs as **root**, reads
`/etc/claude-loop/` directly, and calls `runuser -u claude` for the two things that must
not be root: the session, and every command touching the working tree. The token exists
only on the root side and is passed per-command, never exported.

**State the exposure plainly.** A session on this host can read its own home and reach
whatever the LAN serves unauthenticated. It **cannot** read the App key or the Plane PAT,
cannot run the broker, and cannot obtain a GitHub token — `runuser` drops privilege and
cannot raise it, and there is no sudoers entry to abuse. Verify that rather than trusting
it: `runuser -u claude -- /usr/local/sbin/claude-loop-broker mint-token` must fail.

**The push is the one root command that touches the repo**, and it pushes to an explicit
URL rather than to `origin`, so git updates no remote-tracking ref. That keeps root from
writing a root-owned object into a `claude`-owned `.git` and breaking the next session.

⚠ **Branch protection is the only thing that stops that token merging.** `contents: write`
and `pull_requests: write` are the permissions that merge; nothing about a GitHub App
withholds that. What withholds it is `required_approving_review_count: 1` on `main`, which
the App is expected to be unable to satisfy for its own pull request. If that count ever
drops to zero, this identity can merge unreviewed work the same afternoon.

⚠ **`enforce_admins` stays `false`.** It is not the missing half of that control, and
turning it on deadlocked the repo for an hour on 2026-09-12: in a one-person org nobody can
approve anything, because an author cannot approve their own pull request and the admin
bypass is what was covering that. It only ever constrained Pedro.

⚠ **"An App cannot approve its own pull request" is still untested.** It is the assumption
the whole arrangement rests on, and the test meant to prove it ran as an admin and showed
the opposite case instead. Treat the guarantee as designed rather than verified until the
App has opened a pull request and the merge endpoint has refused it. Read
`docs/runbooks/claude-loop.md` before enabling, and re-read it before relaxing anything on
`main`.

**Turning it off** is `claude_loop_enable=false` and a play re-run, which stops and disables
the timer. Pausing without a play run is a sentinel file — see the runbook.
