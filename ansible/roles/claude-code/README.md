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
| Runs as | `claude`, a non-root user with no sudo |
| Serves | one `claude remote-control` server per entry in `claude_remote_sessions` |

## What Ansible cannot do, and why

Remote Control requires signing in to a claude.ai account on a Pro, Max, Team or
Enterprise plan. **API keys and long-lived `claude setup-token` tokens are refused** — the
feature does not accept them, so there is no unattended path to an eligible login. The same
is true of `gh`.

So this role installs, configures, renders the units, and stops. `claude_remote_enable`
defaults to `false`, and that default is load-bearing: a server started before the login
exists exits immediately, and systemd restarts it until the unit's start limit trips —
turning a missing step into a failed unit that reads like a broken host.

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

5. **Hand it to systemd:**

   ```sh
   ansible-playbook playbooks/configure-claude-code.yml -e claude_remote_enable=true
   ```

6. **Optional — let it open PRs.** `gh auth login` as the `claude` user.

## Verify

A unit that is `active` is not a server that registered. Read the log for the session URL,
then look for the session itself:

```sh
systemctl status claude-remote-iac
journalctl -u claude-remote-iac -n 50 --no-pager
```

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
feature reporting itself unavailable. **Untrusted workspace**: the trust dialog was
accepted somewhere other than the project directory, so accept it again from
`~/work/petedio/iac`.

**If `systemctl start` answers `Start request repeated too quickly`,** the unit tripped the
`StartLimitBurst` in its `[Unit]` section and is parked in `failed`. Clear it with
`systemctl reset-failed claude-remote-<name>`, then start it. The play does this for you
before starting, so a re-run with `-e claude_remote_enable=true` is not blocked by the
wreckage of the run before it.

If the server turns out to want a terminal it does not have under systemd, run it in a
detached `tmux` session as the `claude` user instead (`tmux` is installed for this) and
leave the unit disabled. That is a fallback, not the design — record it here if you need it,
so the next person does not rediscover it.

## Operating it

**Add a project.** Append to `claude_remote_sessions` and re-run the play. Each entry gets
its own unit, so one project's crash leaves the others serving. `spawn: worktree` gives
each on-demand session its own git worktree; `same-dir` shares the directory and lets
concurrent sessions collide.

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

Sessions start in `bypassPermissions` (`claude_permission_mode`), chosen deliberately for
this host: its reason to exist is work you drive from a phone, and a permission prompt you
cannot see is a stall.

Be clear about what that means. Claude Code's own guidance for the mode is "isolated
containers and VMs only", and **this container is not isolated from the lab** — it sits on
the LAN with Vault, Proxmox and Postgres. The role provisions no outbound credential: the
only key it places is your *public* key, authorizing inbound SSH. So a session reaches what
the LAN serves unauthenticated, plus whatever you add by hand afterwards — note that
`gh auth login` leaves its OAuth token in `~/.config/gh/hosts.yml`, under the same user the
sessions run as.

Deny rules still apply in this mode; allow rules do not. ⚠ But those deny rules live in
`~/.claude/settings.json`, which is owned by `claude` — the user the sessions run as — so a
session can rewrite them. To make them hold, put them in root-owned
`/etc/claude-code/managed-settings.json` instead. The same goes for `~/.bashrc` and
`~/.ssh/authorized_keys`: as seeded, a session can persist its own access.

Walking it back is one variable and a play re-run: set `claude_permission_mode` to `default`
(Manual) or `acceptEdits`.

The mode is also why the session user is not root. Claude Code refuses `bypassPermissions`
as root or under sudo on Linux, so a unit running as root would fail at startup.
