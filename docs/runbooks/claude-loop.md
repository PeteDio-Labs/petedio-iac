# Runbook — the ticket-driven work loop on claude-247 (PET-399)

A systemd timer on `claude-247` takes one Plane work item carrying the `agent-ready` label,
runs `claude -p` against it, and opens a **draft** pull request on `PeteDio-Labs/petedio-iac`
with a table diffing what the item asked for against what shipped. One item per tick. No
draining, no parallelism, and nothing here ever merges.

> [!CAUTION]
> **This host now holds a credential that can push and open pull requests, and sessions on
> it run in `bypassPermissions`.** `contents: write` + `pull_requests: write` are also the
> permissions that *merge*. Nothing about a GitHub App withholds that — the one required
> approving review on `main` does, and that guarantee is **designed rather than verified**.
> **Read "The one control that matters" below before you change anything about `main`.**

| | |
|---|---|
| Host | `claude-247` — `192.168.50.247`, VMID 247, pve03 |
| Role | `ansible/roles/claude-code` (`tasks/loop.yml`, `tasks/loop-units.yml`) |
| Deploy | `gh workflow run ansible-claude-247.yml --ref main`, on the homelab runner (PET-515). Fallback, and the only way to switch the timer: `scripts/deploy-claude-247.sh` — was `deploy-claude-loop.sh`; renamed in PET-493, when it took on the workspace mirror's App as well |
| Tick | `scripts/claude-loop-tick.sh` → `/usr/local/sbin/claude-loop-tick` on the host, root `0755` |
| Units | `claude-loop.timer` → `claude-loop.service` |
| Heartbeat | `/var/lib/claude-loop/last-tick.json`, root `0644`, read by `scripts/lab-verify.sh` |
| Secrets | `/etc/claude-loop/{plane.env,github.env,app.pem}`, root `0400` |
| Broker | `/usr/local/sbin/claude-loop-broker`, root `0500` |
| State | `/var/lib/claude-loop/`, root `0755` — claim records under `items/`, the lock, and the tick's scratch (PET-441) |
| Prompt | `/usr/local/share/claude-loop/prompt.md`, root `0644` — root renders it into the per-tick dir (PET-441) |
| Loop home | `~/loop`, `claude`-owned — holds only the `PAUSED` sentinel and the per-tick `run/` dir now (PET-441) |

---

## The one control that matters

The loop it replaces was retired partly because **it merged its own work** (PET-265). This
one cannot, and it is worth being precise about why, because the reason is not in this
repository:

1. **`main` requires one approving review.** GitHub does not let an identity approve a pull
   request it authored, so the bot is expected to be unable to supply its own.
2. **Every pull request opens as a draft.** A draft cannot be merged by anyone until a human
   marks it ready, and the loop never does — the tick passes `--draft` and the prompt
   forbids the session from changing it. The session has no token to change it with either.

The second is a convenience. **The first is the control.** If the required review count on
`main` ever goes to zero, this identity can merge unreviewed work the same afternoon.

Read the protection back rather than trusting that it is set. As of 2026-09-12 it answers
`["validate","gate"]` / `strict: true` / `reviews: 1` / `enforce_admins: false`:

```sh
gh api /repos/PeteDio-Labs/petedio-iac/branches/main/protection \
  --jq '{admins:.enforce_admins.enabled,
         reviews:.required_pull_request_reviews.required_approving_review_count,
         strict:.required_status_checks.strict,
         checks:.required_status_checks.contexts}'
```

> [!CAUTION]
> **The control above is still an assumption. Prove it before you trust it.**
>
> "A GitHub App cannot approve its own pull request" is reasoning, not evidence. The test
> meant to demonstrate it ran as an admin and demonstrated the opposite case instead — it
> merged an unapproved PR (#292) and read as a successful gate test.
>
> To prove it: have the **App** open a pull request and attempt the merge with the App's
> own token. Never against `main` — `PUT /repos/{owner}/{repo}/pulls/{n}/merge` has no
> dry-run form, and a merge to `main` triggers apply-on-merge.
>
> ⚠ **The throwaway base must be protected, or the test proves nothing.** Branch protection
> here applies to `main` and to nothing else, so a base branched off `main` inherits no
> rules. The App would merge it and return `200` — which means "this branch has no rules",
> not "the App can merge protected branches". Give the base
> `required_approving_review_count: 1` and no required checks, so a refusal cannot be blamed
> on a missing status check.
>
> ⚠ **Run a control arm, or a refusal is unreadable.** Repeat the whole thing against a
> second, *unprotected* throwaway base. Without it, `405` on the protected base is
> indistinguishable from a broken token, and "the App cannot merge" would be recorded on the
> strength of a credential that could not merge anything.
>
> | protected base | unprotected base | meaning |
> |---|---|---|
> | refuses | merges | the premise holds — the review requirement binds the App |
> | merges | merges | **the premise is false.** PET-399 does not ship as designed |
> | refuses | refuses | the token is broken. Nothing was learned; fix the mint and re-run |
>
> ⚠ And do not read the answer off the pull request's own status fields.
> `mergeStateStatus=BLOCKED` with `reviewDecision=REVIEW_REQUIRED` is what a PR shows on a
> protected branch — an admin token merged one showing exactly that. **`BLOCKED` describes
> the path, not what a given identity can do.** The check has to be made with the identity
> that would do the merging.
>
> A script implementing this, with both arms and the cleanup, is at `~/pet399-proof.sh` on
> the Mac. As of 2026-09-12 it has **not been run** — the session that wrote it was blocked
> from minting a token, correctly. The premise remains unproven.

> [!WARNING]
> **`enforce_admins` stays `false`. Do not "fix" it.**
>
> It looks like the missing half of the control and it is not. Setting it true on
> 2026-09-12 deadlocked the repository for an hour: in a one-person org an author cannot
> approve their own pull request, so with the admin bypass gone there is nobody left who
> can approve anything, and **nothing can merge at all**. Four pull requests (#293, #294,
> #295 and `petedio-vault#23`) sat unmergeable until it was reverted.
>
> `enforce_admins` only ever constrained Pedro, who is not the identity this control exists
> for. The bot is not an admin, so the review requirement binds it with `enforce_admins`
> off.

> [!WARNING]
> **Never add a path-filtered workflow to `required_status_checks`.** A required check with
> a `paths:` filter never reports on a PR outside those paths, and GitHub waits for it
> forever at `Expected — waiting for status to be reported`. `ansible-validate` had such a
> filter removed in #293 for exactly this reason — `docs/GOTCHAS.md`.

> [!CAUTION]
> **`ansible-validate` is NOT a required check, whatever a green tick suggests.** Read back
> live on 2026-09-12, `.required_status_checks.contexts` is `["validate","gate"]`. PET-397
> made it required; reverting `enforce_admins` silently took it back out, because branch
> protection is a **full-replacement `PUT`** and the revert did not resend the contexts.
>
> So the job runs on every pull request, goes green, and blocks nothing. That is worse than
> a check known to be advisory: this one is *believed* to be required, which is the state
> the six green-over-nothing tickets describe. This runbook asserted it was required until
> the contexts were actually read.
>
> Restoring it is Pedro's call. If he does, `PATCH` the sub-resource rather than `PUT` the
> object, and read the contexts back afterwards:
> `gh api -X PATCH /repos/PeteDio-Labs/petedio-iac/branches/main/protection/required_status_checks -f 'contexts[]=validate' -f 'contexts[]=gate' -f 'contexts[]=ansible-validate'`
>
> The path-filter hazard above is still not exercised — every PR merged since #293 happened
> to touch `ansible/**`. The first Terraform-only or docs-only PR tests it, but only once
> the check is required again.

---

## First build

Everything before step 4 is one-time.

1. **Create the GitHub App.** Installed on `petedio-iac` **only**, with `contents: write`
   and `pull_requests: write` and nothing else. Generate a private key and keep the `.pem`.

2. **Seed Vault.** `kv/services/claude-loop`, fields `app_id`, `installation_id`,
   `app_pem`. The key must keep its newlines — `scripts/claude-247-extra-vars.sh`, which both
   deploy paths run, refuses a single-line PEM, because `openssl`'s complaint about one points at the signature rather than the
   field.

   The Plane PAT is already at `kv/services/plane` field `api_key`; the loop reuses it
   rather than minting a second Plane identity. No `vault-config` change is needed for it:
   the `ansible` policy the fallback uses reads `kv/data/services/*`, and the
   `claude-247-deploy` policy the workflow uses names both paths (PET-515).

3. **Create the label.** The project had no labels at all when this was written, so this is
   a creation step and not a lookup. Add `agent-ready` in Plane. The broker exits non-zero
   if it cannot find it, rather than reporting an empty queue.

4. **Deploy.** Dispatch the workflow from a machine whose `gh` holds the `workflow` scope. It
   runs on the homelab runner and logs in to Vault as the `claude-247-deploy` role:

   ```sh
   gh workflow run ansible-claude-247.yml --ref main
   ```

   The fallback runs from your machine, not from 247 — the AppRole login happens on yours:

   ```sh
   ./scripts/deploy-claude-247.sh
   ```

   The play lands the secrets, installs the broker, clones the loop's own copy of the repo
   into `~/loop/iac`, and **leaves the timer stopped**. It finishes by minting a token as
   root, so a broken key fails here rather than at 03:00 in a tick nobody is watching.

The loop's clone needs no trust step. `claude -p` skips the workspace trust dialog, and the
session runs with no MCP server, on purpose (PET-487).

---

## Before you enable it

**Run one tick by hand and read what it did.** The timer stays off until a draft pull
request from the bot has been looked at by a person.

The tick runs as root and drops to `claude` itself, so run it as root. claude-247 has no
`sudo` and no operator account, so log in as root with the key the inventory uses.

The tick reads its settings from the unit's `Environment=` lines: `HOME`, `PATH`, `CLAUDE_BIN`
and every `CLAUDE_LOOP_*` value. A root shell holds none of them, and the model has no
fallback (`PET-484`). So pass the unit's environment to the tick you run by hand:

```sh
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.247
/usr/local/sbin/claude-loop-broker next-item   # {"examined":41,"labelled":1,…}
env -i $(systemctl show claude-loop.service -p Environment --value) \
  /usr/local/sbin/claude-loop-tick             # one tick, in the foreground
cat /var/lib/claude-loop/last-tick.json
```

The item must carry `agent-ready` and sit in `Todo`, or `next-item` reports
`"labelled":1,"eligible":0` and the tick finds nothing to take.

`env -i` starts from an empty environment, so nothing in the root shell reaches the session.
The tick then runs with the values a timer-run tick gets. A tick that refuses with
`CLAUDE_LOOP_MODEL is empty` ran without them.

**Then check the boundary holds, rather than assuming it.** This must fail:

```sh
ssh claude@192.168.50.247 '/usr/local/sbin/claude-loop-broker mint-token'   # permission denied
ssh claude@192.168.50.247 'sudo -n true'                                    # no sudo on this host
```

If either succeeds, stop: the `claude -p` session runs as that user, its instructions come
from a work item, and PET-408 is back.

**Then check the session got no connectors.** The loop user is logged in to Pedro's
claude.ai account, and a plain `claude -p` loads every connector on it: Gmail, Calendar,
Drive and the rest. So the tick starts the session with three switches that turn them off,
and it proves the result first. It runs `claude mcp list` as `claude`, in the checkout, with
the session's two claude.ai switches, and stops unless the list is empty (PET-487). A tick you
run by hand logs that command line with its switches, then `connector proof passed`. The full
list stays on the host:

```sh
cat /home/claude/loop/run/<ITEM>/mcp-list.log   # No MCP servers configured. …
```

The proof shows that the session had no MCP server. To show that it called no MCP tool, count
those tool names in its transcript. `session.log` cannot show this, because it holds only the
session's final message. The newest transcript for the checkout is the tick's session, so run
this right after the tick:

```sh
F=$(ls -1t /home/claude/.claude/projects/-home-claude-loop-iac/*.jsonl | head -1)
date -u -r "$F"                                       # a time during the tick
grep -c '"type":"tool_use"' "$F"                      # above 0: the session called tools
grep -o '"name":"mcp__[^"]*"' "$F" | sort | uniq -c   # prints nothing
```

The last command is a check that can fail. On the PET-420 session of 2026-09-21, before
PET-487, it printed three Plane tools.

> [!WARNING]
> **The switches stop Claude Code from loading the connectors. They do not stop a hostile
> session.** The loop user can read its own `~/.claude/.credentials.json`, which holds
> Pedro's claude.ai login, and it owns the Claude Code install. A session could use the login
> from a process of its own, or replace the binary the next tick runs. The tick's unit keeps
> systemd's default `KillMode=control-group`, so every process the session started ends with
> the tick. Without linger, `claude` has a user manager only while someone is logged in as
> `claude`. Cron is the gap: `claude` may install a crontab, and cron runs it after the tick
> ends (checked on 2026-09-21). PET-488 tracks separating the login from the session, and
> denying `claude` a crontab.

Label one small, real work item first. Check the draft pull request has the spec-diff
comment, that its author is the App and not you, and that the `Merge` button is unavailable.

Then hand it to systemd:

```sh
./scripts/deploy-claude-247.sh -e claude_loop_enable=true
./scripts/lab-verify.sh | grep -i "work loop"
```

> [!NOTE]
> `systemd_service: state=started` returns immediately and throws the result away, so the
> play cannot tell you whether a tick succeeded. To watch one and get its exit code, borrow
> the `vault-unseal` idiom: `systemctl start --wait claude-loop.service; echo $?`.

---

## Operating it

**Pause it** without a play run, without root, and without disabling the timer. The timer
keeps firing and the heartbeat keeps proving the host is alive, which is why this is better
than stopping the unit:

```sh
ssh claude@192.168.50.247 'touch ~/loop/PAUSED'   # park
ssh claude@192.168.50.247 'rm ~/loop/PAUSED'      # resume
```

`lab-verify` reports a paused loop as a `skip` that names the sentinel, so a `PAUSED` file
nobody remembers setting cannot masquerade as a quiet queue.

**Turn it off properly:**

```sh
./scripts/deploy-claude-247.sh -e claude_loop_enable=false
```

Both branches converge — this stops *and* disables the timer, rather than leaving a running
one behind. Most gated timers in this tree do not do that; this role does.

**Kill a tick that is running.** claude-247 has no `sudo` and no operator account, so log in
as root with the key the inventory uses:

```sh
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.247 'systemctl stop claude-loop.service'
```

**Retry an item the loop gave up on.** After `claude_loop_max_attempts` failed ticks the
loop stops picking an item up. Clear its claim to put it back in the queue:

```sh
ssh claude@192.168.50.247 'cat /var/lib/claude-loop/items/PET-500.json'   # read why first — 0644, unprivileged
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.247 'rm /var/lib/claude-loop/items/PET-500.json'   # claude cannot; root owns it (PET-441)
```

Fix the underlying problem first. The claim file records the reason for every attempt.

**Change the model.** Every tick passes `--model` to `claude -p`. The value is
`claude_loop_model` in `roles/claude-code/defaults/main.yml`, and it ships as `sonnet`. An
alias (`sonnet`, `opus`, `haiku`) follows its family to each release, and a full model ID
pins one model. To change it, set the variable in
`ansible/inventory/host_vars/claude-247.yml`, merge the pull request, and re-run the play:

```sh
gh workflow run ansible-claude-247.yml --ref main   # or ./scripts/deploy-claude-247.sh
```

Don't pass it with `-e`. The next play run without the flag puts the default back, and no
commit records that the loop's cost against the shared Max quota changed. `PET-431` is
that failure for `claude_remote_enable`.

To confirm what the unit carries and what a tick ran, read the unit and the claim record.
Both reads work as the `claude` user:

```sh
ssh claude@192.168.50.247 'systemctl show claude-loop.service -p Environment' | tr ' ' '\n' | grep MODEL
ssh claude@192.168.50.247 'cat /var/lib/claude-loop/items/PET-500.json'   # carries "model"
```

The tick also logs `running claude -p (model sonnet, …)`. A tick you run by hand prints
that line to your terminal. A timer-run tick writes it to the unit's journal, which only
root reads on this host.

The tick has no fallback for this value. With `CLAUDE_LOOP_MODEL` missing or blank, the tick
fails before it asks the broker for work, and the heartbeat's `detail` names the setting.
Without that refusal a tick runs the account default model, which changes when Anthropic
ships a model (`PET-484`).

Claude Code owns the list of valid names, so the tick checks only the value's shape. For a
name it does not know, `claude -p` exits 1 and prints `There's an issue with the selected
model` (measured on 2026-09-21: Claude Code 2.1.270 on 247, and 2.1.170 on the Mac). The
tick records the item as failed, the attempt counts, and `session.log` holds the message.
After you correct the name, clear the claim as described above.

**Read what a tick actually did.** Session logs stay on the host and are never uploaded:

```sh
ssh claude@192.168.50.247 'ls ~/loop/run/'
ssh claude@192.168.50.247 'cat ~/loop/run/PET-500/session.log'
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.247 'journalctl -u claude-loop.service -n 100 --no-pager'
```

Read the journal as root. The `claude` user is in neither `adm` nor `systemd-journal`, so as
`claude` the same command prints `-- No entries --` and exits 0, whatever the unit logged.

---

## Rotating the App private key

Do this on a schedule. It is the one credential here with no expiry — the installation
tokens the broker mints last an hour whether or not anything uses them, but the key that
signs for them lasts until someone replaces it.

1. Generate a new private key in the App's settings. **Do not delete the old one yet.**
2. Update `kv/services/claude-loop` field `app_pem`.
3. `gh workflow run ansible-claude-247.yml --ref main`, or `./scripts/deploy-claude-247.sh` — the play re-lands the key and mints a token with it,
   so a bad paste fails the play.
4. Delete the old key in GitHub.

To revoke the loop's access immediately and completely, uninstall the App from the
repository. That invalidates every token it has minted; no play run is needed.

---

## When something is wrong

**`lab-verify` says "timer enabled, last tick … — the loop did not run".** The heartbeat is
older than its own `max_age_sec`. The line also prints when systemd last triggered the
timer, and those two facts point at different faults: if systemd never fired it, look at
`systemctl list-timers claude-loop.timer`; if systemd fired it and the heartbeat did not
move, the tick died before its EXIT trap and `journalctl -u claude-loop.service` has the
reason.

**`lab-verify` says "it has never completed a tick".** The timer is enabled but there is no
heartbeat. Run one tick by hand — it will say what is missing.

**Ticks fail at `the broker could not list work items`.** The broker refuses to report an
empty queue over a structural problem, so this is one of: the label does not exist, there
is no `Todo` state in the project, Plane is unreachable, or the PAT is rejected. It prints
which.

**A tick fails at `the session wrote no spec-diff`.** Working as intended: the session did
not produce the table, so no pull request was opened. Read
`~/loop/run/<ITEM>/session.log`. A pull request without that table is the exact artifact
this loop exists to make impossible, so do not relax this check — replace it if you must,
but do not remove it.

**A tick fails at `a CLAUDE.md above the checkout`.** The tick refuses to start when a
`CLAUDE.md` or `.claude/CLAUDE.md` sits in any strict ancestor of the checkout `~/loop/iac`,
because `claude -p` reads `CLAUDE.md` from the working directory up to the root — a file the
session could plant in one tick to steer the next (PET-441). The checkout's own `CLAUDE.md`
is expected and is not checked. The usual culprit is the loop user's `~/.claude/CLAUDE.md`;
move it, or whatever the detail names, out of the checkout's ancestry. The tick names the
directory it found, claims no item, and runs no session.

**A tick fails at `the connector proof failed`.** Working as intended: before the session,
the tick asked Claude Code which MCP servers the session would load, and the answer was not
"none" (PET-487). No session ran, no pull request opened, and the failure counts against the
item's attempts. The detail gives the exit code of `claude mcp list` and the server names, or
`no server names in its output`. The full output is in `~/loop/run/<ITEM>/mcp-list.log`. The
heartbeat carries names only, because a server's URL or command can carry a key.

- **A `claude.ai` name** means Claude Code ignored `ENABLE_CLAUDEAI_MCP_SERVERS=false`. An
  upgrade can rename or drop that switch. Find its replacement in the release notes, then
  change the tick and the harness together.
- **Any other name** comes from an MCP scope Claude Code reads for the checkout: the loop
  user's `~/.claude.json`, or an `.mcp.json` in the checkout. A previous session may have
  written it. Remove it. To find the session that wrote it, list the transcripts that name it:
  `grep -l '<name>' /home/claude/.claude/projects/-home-claude-loop-iac/*.jsonl`. A
  `session.log` holds only its session's final message.
- **No names** means `claude mcp list` failed, or printed something the tick does not
  recognize, such as new wording after an upgrade. The log shows which.

Do not relax the check. It is the only part of the tick that notices when an upgrade changes
what the switches do, or when a session plants a server for the next tick.

**Two pull requests for one work item.** Should not happen: the broker only returns `Todo`
items, `plane-sync.yml` moves an item to In Progress when its draft PR opens, the tick keeps
its own claim record, and it refuses to push a branch that already exists on `origin`. If it
happens anyway, the claim records in `/var/lib/claude-loop/items/` are the place to start.

---

## Changing the tick

`scripts/test-claude-loop-tick.sh` drives the tick through every path it has — including
the ones that must *not* open a pull request — against a throwaway git remote and stubbed
the broker, `claude` and `gh`. It needs no credential and touches no network:

```sh
./scripts/test-claude-loop-tick.sh
```

Run it on Linux, such as on 247 as `claude`. The tick needs `flock` and GNU `timeout`, which
macOS lacks, so on a Mac most scenarios fail (`docs/GOTCHAS.md`).

Run it before and after you touch `claude-loop-tick.sh`. It found two real defects while it
was being written, both of which passed the first tick and failed the second.

Scenarios 12-14 model a **hostile** session — one that repoints `origin`, that hides the
rewrite in `url.<base>.insteadOf`, and that plants a `pre-push` hook. They exist because
their absence is what let PET-409 through: the first eleven scenarios all stub a session
that behaves itself, and 37 assertions passed green over a credential helper that would
have handed the GitHub token to whatever remote the session chose. The session runs as this
user, in this directory, driven by work-item text the loop does not control. Assume it is
hostile, and when you add a scenario ask what it assumes the session will not do.

Scenarios 25-30 cover the connector switches (PET-487). The stub `claude` answers `claude
mcp list` and records each call's arguments and environment, so these scenarios check what
the tick passed, not only what it logged. Scenario 28 is the hostile one: a session plants
an MCP server for the next tick. `--strict-mcp-config` hides that server from the session,
so only the proof can see it.
