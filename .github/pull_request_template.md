<!--
  petedio-iac PR template (PET-149). The verification-evidence block below is the SINGLE
  place the reviewer (PET-135) and Pedro read to judge a PR — fill it; don't make them
  re-derive it. Delete guidance comments as you go. Loop PRs MUST arrive with this filled.
-->

## What & why

<!-- One or two lines: what this changes and why. -->

Closes **PET-____**.

## What was done

<!-- Bullet the concrete changes (files / resources / roles touched). -->

-

## Verification evidence

> The loop verifies what's cheap on-host; the **authoritative** `plan`/`--check` and every
> apply are the operator's (hard rules). Fill every row — "n/a" is a valid answer, blank is not.

**Terraform** (if any `*.tf` changed; else "no `.tf` changed"):
- `terraform fmt -check -recursive`: <!-- pass / fail -->
- `terraform validate`: <!-- pass / fail / n/a — note which workspace(s): homelab, vault-config -->
- **Plan impact** (add/change/destroy): <!-- e.g. "0/0/0 — no .tf changed" · "move-only (0/0/0)" ·
  "TF changed → operator runs the authoritative plan (loop has no backend creds); see the
  apply-on-merge log". An empty/no-op plan where a change was intended is a FAILURE, not a pass. -->

**Ansible** (if any playbook/role changed; else "no Ansible changed"):
- `ansible-playbook --syntax-check`: <!-- pass / fail / n/a -->
- `yamllint` / `ansible-lint`: <!-- pass / no NEW violations vs main / fail -->

**Other** (if applicable):
- Tests (e.g. Co-latro `bun test`): <!-- pass / fail / n/a — a failing-test PR must be a DRAFT -->
- Scripts: <!-- bash -n / shellcheck / a real dry-run, if a script changed -->

## Gates

- [ ] **Not `import-gated`.** If this is `import-gated` (a human `terraform import` is required
      before merge), say so here and confirm the agreed gate: agents never advance it past PR,
      and merge only after plan-on-PR / the operator's plan is a **no-op**. (PET-144)
- [ ] **No secrets** in the diff or this description — Vault paths referenced by name only.
- [ ] Touches **one repo** only (this one).

## Manual steps for Pedro

<!-- Anything the loop can't safely do: terraform apply/import/state, Vault-config apply,
     SSH/Ansible against live hosts, repo-settings or network changes, MinIO bucket creation,
     etc. Write the exact commands. "None" if there are none. -->

None.

---
<sub>🤖 Loop PRs: authored by the agent loop on agent-loop-242 — **never merged by an agent** (hard rule 2). Pedro is the only merger.</sub>
