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
| Serves | one `claude remote-control` server per entry in `claude_remote_sessions`, plus the work-loop timer when `claude_loop_enable` is set |

## What Ansible cannot do, and why

Remote Control requires signing in to a claude.ai account on a Pro, Max, Team or
Enterprise plan. **API keys and long-lived `claude setup-token` tokens are refused** — the
feature does not accept them, so there is no unattended path to an eligible login. The same
is true of `gh`.

So this role installs, configures and renders the units, and starts them only once the
operator steps are done. `claude_remote_enable` defaults to `false`, so a host nobody has
bootstrapped gets stopped units. claude-247 declares `true` in
`inventory/host_vars/claude-247.yml`, and even then the role refuses to start a unit until
the one-time consent is on disk: a server started without it waits at its prompt forever
while systemd reports it active (PET-431).

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

6. **Optional — let it open PRs.** `gh auth login` as the `claude` user.

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
`Capacity: 0/32` and a `https://claude.ai/code?environment=…` URL. After that the server
redraws its status line into the journal about five times a second, so
`journalctl -u claude-remote-iac -n 50` shows nothing but redraws.

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
feature reporting itself unavailable. **Untrusted workspace**: the trust dialog was
accepted somewhere other than the project directory, so accept it again from
`~/work/petedio/iac`.

**If `systemctl start` answers `Start request repeated too quickly`,** the unit tripped the
`StartLimitBurst` in its `[Unit]` section and is parked in `failed`. Clear it with
`systemctl reset-failed claude-remote-<name>`, then start it. The play does this for you
before starting, so a re-run with `-e claude_remote_enable=true` is not blocked by the
wreckage of the run before it.

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
the LAN with Vault, Proxmox and Postgres. Until the work loop, the role provisioned no
outbound credential: the only key it placed was your *public* key, authorizing inbound SSH.
So a session reached what the LAN serves unauthenticated, plus whatever you added by hand
afterwards — note that `gh auth login` leaves its OAuth token in `~/.config/gh/hosts.yml`,
under the same user the sessions run as.

⚠ **The work loop changes that.** See "What the loop changes about the isolation story"
below before you set `claude_loop_enable`.

Deny rules still apply in this mode; allow rules do not. ⚠ But those deny rules live in
`~/.claude/settings.json`, which is owned by `claude` — the user the sessions run as — so a
session can rewrite them. To make them hold, put them in root-owned
`/etc/claude-code/managed-settings.json` instead. The same goes for `~/.bashrc` and
`~/.ssh/authorized_keys`: as seeded, a session can persist its own access.

Walking it back is one variable and a play re-run: set `claude_permission_mode` to `default`
(Manual) or `acceptEdits`.

The mode is also why the session user is not root. Claude Code refuses `bypassPermissions`
as root or under sudo on Linux, so a unit running as root would fail at startup.

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
