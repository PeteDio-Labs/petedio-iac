---
paths:
  - ".github/**"
---

# CI rules

Each rule is the short form. The narrative is in the cited `docs/GOTCHAS.md` section.

- Jobs that need the LAN run on `[self-hosted, linux, x64, homelab]`. A GitHub-hosted runner can't reach `192.168.50.0/24` (docs/GOTCHAS.md: "CI / runner").
- `[self-hosted, homelab]` also matches the arm64 pi, so always pin `x64` (docs/GOTCHAS.md: "`runs-on: [self-hosted, homelab]` also matches the arm64 pi (PET-355)").
- A Vault 403 has four causes. Set `path: jwt-github` and `jwtGithubAudience`, then read `/opt/vault/logs/vault_audit.log` on 223 before the role (docs/GOTCHAS.md: "A Vault 403 says `permission denied` and means four different things (PET-355)").
- GitHub runs scheduled workflows hours late and in bunches. Don't rely on cron staggering to keep jobs apart (docs/GOTCHAS.md: "Scheduled workflows do not fire near their cron (PET-363)").
- A required check must run on every PR. A `paths:` filter on `pull_request` leaves it waiting forever, so filter only `push` (docs/GOTCHAS.md: "A required status check with a `paths:` filter hangs every PR that misses it (PET-399)").
- Keep `enforce_admins` false. Change status checks with `PATCH …/required_status_checks` and read them back. The merge endpoint has no dry run (docs/GOTCHAS.md: "Branch protection in a one-person org (PET-399)").
- Before pushing, run every step the CI workflow runs, not only the tests (docs/GOTCHAS.md: "Run the commands CI runs, not one of them").
- `ignoreNotFound` tolerates a missing path, not a missing key. For an optional secret, use `continue-on-error` on a step after a strict one (docs/GOTCHAS.md: "`ignoreNotFound` covers a missing PATH, not a missing KEY").
- The claude-loop App can't push `.github/workflows/**`, and must not be allowed to. Do workflow edits by hand (docs/GOTCHAS.md: "A GitHub App cannot push `.github/workflows/**` without `workflows` permission").
- To widen a reusable workflow's permissions, grant them in every caller first. A job asking for more than its caller grants hits `startup_failure` and leaves no log (docs/GOTCHAS.md: "A reusable workflow that asks for more than its caller granted never starts, and leaves no log (PET-430)").
