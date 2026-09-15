---
paths:
  - "ansible/**"
---

# Ansible rules

Each rule is the short form. The narrative is in the cited `docs/GOTCHAS.md` section.

- Container features are declared in `roles/lxc-features/defaults/main.yml`. Pass the union to `pct set --features`, because it replaces the whole string (docs/GOTCHAS.md: "Proxmox / bpg").
- The minimal LXC template has no sudo, and service accounts use `nologin`. To act as one, use `runuser -u <user> -- <cmd>`, not `become_user` or `su` (docs/GOTCHAS.md: "`become_user` needs sudo, and the minimal LXC template has none (PET-355)").
- Uptime Kuma's `applyExisting` attaches nothing. Set `notificationIDList` per monitor, accept list or dict, and count unattached monitors against `kuma.db` (docs/GOTCHAS.md: "Uptime Kuma's `applyExisting` does not attach to existing monitors (PET-374)").
- A DM-only discord.js bot needs `Partials.Channel`. Defer an interaction before slow work (docs/GOTCHAS.md: "Discord: an app can DM you with no shared server (PET-375)").
- Vault on 223 seals nightly under `vzdump` `mode: stop`. Keep both unseal watchers, pi and Mac. Unseal with `PUT /v1/sys/unseal`, never `vault operator unseal` (docs/GOTCHAS.md: "Vault seals every night, and two watchers open it (PET-373)").
- Remote Control needs an interactive claude.ai login and a hand-answered consent prompt. Declare `claude_remote_enable` in `host_vars`, never with `-e` (docs/GOTCHAS.md: "Claude Code as a service — the Claude host (247) (PET-396)").
- `-e var=false` is a truthy string, so gate every read with `| bool` (docs/GOTCHAS.md: "Claude Code as a service — the Claude host (247) (PET-396)").
- Put Remote Control flags after the `remote-control` subcommand. Set `PATH` and `HOME` in the unit, because `.bashrc` is skipped under systemd (docs/GOTCHAS.md: "Claude Code as a service — the Claude host (247) (PET-396)").
- `SendMessage` delivers only within one permission-mode class, and it reports success either way. Count delivery by the reply, and don't set `crossSessionInbound: accept` (docs/GOTCHAS.md: "Claude Code as a service — the Claude host (247) (PET-396)").
- Lint `roles/ playbooks/`, never `.`, and floor the processed-file count. Suppress with `# noqa` at the site, with the reason above it (docs/GOTCHAS.md: "`ansible-lint <dir>` can examine nothing and call it a pass (PET-397)").
- `set -o pipefail` needs `args: executable: /bin/bash`. When renaming a handler, move every `notify:` in the same commit (docs/GOTCHAS.md: "`ansible-lint <dir>` can examine nothing and call it a pass (PET-397)").
- Don't give a program that starts `claude -p` a sudo grant, because the session inherits its UID. Run the parent as root, drop with `runuser`, and remove files with `state: absent` (docs/GOTCHAS.md: "A sudoers grant belongs to the UID, not to the process you wrote it for (PET-408)").
