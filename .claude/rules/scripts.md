---
paths:
  - "scripts/**"
  - "tools/**"
---

# Script rules

Each rule is the short form. The narrative is in the cited `docs/GOTCHAS.md` section.

- `claude -p` accepts `--max-turns`, though `--help` omits it, and skips the trust dialog. Bound it with `timeout` too, under a larger `TimeoutStartSec` (docs/GOTCHAS.md: "Claude Code as a service — the Claude host (247) (PET-396)").
- A health check on 247 attributes :443 sockets to the unit's cgroup. An `active` unit or a journal banner proves nothing (docs/GOTCHAS.md: "Claude Code as a service — the Claude host (247) (PET-396)").
- The loop tick runs as root and drops privilege with `runuser`, which lives in `/usr/sbin`. Push to a URL, not `origin`, with a path-scoped `safe.directory` (docs/GOTCHAS.md: "A sudoers grant belongs to the UID, not to the process you wrote it for (PET-408)").
- A journal line tagged `_LINE_BREAK=eof` was written at an unknown earlier time. Before trusting a string as a marker, find what prints it (docs/GOTCHAS.md: "A journal line's timestamp is when journald committed it, not when it was written (PET-431)").
- Report a push by asking the remote with `git ls-remote`, never from a local SHA or a variable (docs/GOTCHAS.md: "A push that reports success from a variable instead of an exit status").
- Switch on every verdict explicitly, and make an unrecognized value a fault. An `else` that means failure breaks when a third case appears (docs/GOTCHAS.md: "An `else` that means failure is a trap the moment a third case exists").
- `scripts/test-claude-loop-tick.sh` needs `flock`, so run it on 247, not a Mac. Preflight GNU-only dependencies (docs/GOTCHAS.md: "The test suite needs `flock`, which macOS does not ship").
