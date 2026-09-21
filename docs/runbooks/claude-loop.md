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
| Deploy | `scripts/deploy-claude-loop.sh` |
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
   `app_pem`. The key must keep its newlines — `deploy-claude-loop.sh` refuses a single-line
   PEM, because `openssl`'s complaint about one points at the signature rather than the
   field.

   The Plane PAT is already at `kv/services/plane` field `api_key`; the loop reuses it
   rather than minting a second Plane identity. No `vault-config` change is needed — the
   `ansible` policy already reads `kv/data/services/*`.

3. **Create the label.** The project had no labels at all when this was written, so this is
   a creation step and not a lookup. Add `agent-ready` in Plane. The broker exits non-zero
   if it cannot find it, rather than reporting an empty queue.

4. **Deploy.** From your machine, not from 247 — the AppRole login happens on yours:

   ```sh
   ./scripts/deploy-claude-loop.sh
   ```

   The play lands the secrets, installs the broker, clones the loop's own copy of the repo
   into `~/loop/iac`, and **leaves the timer stopped**. It finishes by minting a token as
   root, so a broken key fails here rather than at 03:00 in a tick nobody is watching.

5. **Optional — trust the loop's clone.** `claude -p` skips the workspace trust dialog
   entirely, so the loop runs without this. Do it anyway if you want MCP tools resolving
   inside a tick:

   ```sh
   ssh claude@192.168.50.247 'cd ~/loop/iac && claude'   # accept trust, then /exit
   ```

---

## Before you enable it

**Run one tick by hand and read what it did.** The timer stays off until a draft pull
request from the bot has been looked at by a person.

The tick runs as root and drops to `claude` itself, so run it as root:

```sh
ssh pedro@192.168.50.247
sudo /usr/local/sbin/claude-loop-broker next-item   # {"examined":41,"labelled":1,…}
sudo /usr/local/sbin/claude-loop-tick               # one tick, in the foreground
cat /var/lib/claude-loop/last-tick.json
```

**Then check the boundary holds, rather than assuming it.** This must fail:

```sh
ssh claude@192.168.50.247 '/usr/local/sbin/claude-loop-broker mint-token'   # permission denied
ssh claude@192.168.50.247 'sudo -n true'                                    # no sudo on this host
```

If either succeeds, stop: the `claude -p` session runs as that user, its instructions come
from a work item, and PET-408 is back.

Label one small, real work item first. Check the draft pull request has the spec-diff
comment, that its author is the App and not you, and that the `Merge` button is unavailable.

Then hand it to systemd:

```sh
./scripts/deploy-claude-loop.sh -e claude_loop_enable=true
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
./scripts/deploy-claude-loop.sh -e claude_loop_enable=false
```

Both branches converge — this stops *and* disables the timer, rather than leaving a running
one behind. Most gated timers in this tree do not do that; this role does.

**Kill a tick that is running:**

```sh
ssh pedro@192.168.50.247 'sudo systemctl stop claude-loop.service'   # the claude user has no sudo
```

**Retry an item the loop gave up on.** After `claude_loop_max_attempts` failed ticks the
loop stops picking an item up. Clear its claim to put it back in the queue:

```sh
ssh claude@192.168.50.247 'cat /var/lib/claude-loop/items/PET-500.json'   # read why first — 0644, unprivileged
ssh pedro@192.168.50.247  'sudo rm /var/lib/claude-loop/items/PET-500.json'   # claude cannot; root owns it (PET-441)
```

Fix the underlying problem first. The claim file records the reason for every attempt.

**Read what a tick actually did.** Session logs stay on the host and are never uploaded:

```sh
ssh claude@192.168.50.247 'ls ~/loop/run/'
ssh claude@192.168.50.247 'cat ~/loop/run/PET-500/session.log'
journalctl -u claude-loop.service -n 100 --no-pager
```

---

## Rotating the App private key

Do this on a schedule. It is the one credential here with no expiry — the installation
tokens the broker mints last an hour whether or not anything uses them, but the key that
signs for them lasts until someone replaces it.

1. Generate a new private key in the App's settings. **Do not delete the old one yet.**
2. Update `kv/services/claude-loop` field `app_pem`.
3. `./scripts/deploy-claude-loop.sh` — the play re-lands the key and mints a token with it,
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

Run it before and after you touch `claude-loop-tick.sh`. It found two real defects while it
was being written, both of which passed the first tick and failed the second.

Scenarios 12-14 model a **hostile** session — one that repoints `origin`, that hides the
rewrite in `url.<base>.insteadOf`, and that plants a `pre-push` hook. They exist because
their absence is what let PET-409 through: the first eleven scenarios all stub a session
that behaves itself, and 37 assertions passed green over a credential helper that would
have handed the GitHub token to whatever remote the session chose. The session runs as this
user, in this directory, driven by work-item text the loop does not control. Assume it is
hostile, and when you add a scenario ask what it assumes the session will not do.
