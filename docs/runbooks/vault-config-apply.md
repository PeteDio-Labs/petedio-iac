# Apply vault-config from CI

To apply a `vault-config` change, merge its PR, then dispatch the `vault-config-apply` workflow
on `main`:

1. The `plan` job needs no approval. It prints what the guard examined, each change it allows
   (with added and removed JWT claims), each change it refuses, and a `plan-digest`.
2. Open the run and approve the `apply` job (`lab-write` environment). It re-plans, refuses if the
   digest differs from the `plan` job's, applies the saved plan, and plans again. The second plan
   must be empty.
3. If the guard refuses a change, run `scripts/apply-vault-config.sh` on the Mac instead.

## What the gated path never does

- Delete or replace a resource.
- Change `vault-config-*` policies and roles, the break-glass policy, userpass, MFA, the audit
  device, mounts, the SSH CA, or the `lab-runner` and `pedro` SSH roles.
- Grant a policy path under `sys/`, `auth/` or `identity/`, grant `sudo`, or open a whole mount.
- Attach a privileged policy to a JWT role, or create an SSH role that signs for root.

`scripts/vault-config-guard.py` enforces the list, and the `vault-config-apply` Vault policy denies the
same paths. `python3 scripts/test-vault-config-guard.py` runs the guard's tests.

## First use

The first apply of `vault-config-apply.tf` is a Mac step, because the gated path cannot create its
own role. After it, run the `plan` job alone. A 403 names any path the policy lacks; add it in a
reviewed PR.

## Not included

A Discord alert on each apply. It needs a notify credential this path does not hold.
