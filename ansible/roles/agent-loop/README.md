# agent-loop role — legacy (fleet retired, PET-265 P0)

The agent fleet (worker/engine/reviewer, PET-125/184) that ran on LXC 242 has been
retired — see the [Resume Builder planning doc](https://linear.app/petedillo/document/resume-builder-planning-cd7da4b423e9),
P0. The host is renamed `resume-242` (`environments/homelab/agent-loop.tf`) and is
becoming the Sonia resume-builder app host.

This role no longer has a caller (`configure-agent-loop.yml` and the fleet-only
timer tasks/templates were removed in the same PR that retired the fleet). What's
left is dead code providing base-toolchain tasks (Node.js, Claude Code, gh, Bun,
Postgres test-gate, IaC verify tooling) and the still-reusable **Vault Agent**
block (`agent-loop` AppRole plumbing — kept as-is per the teardown plan). A future
P1 pass either writes a fresh role for the resume-builder app or trims this one
further; until then it is unused and should not be re-applied.
