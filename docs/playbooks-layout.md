# Playbook layout

Playbooks live in one folder per area under `ansible/playbooks/`. A playbook is at
`ansible/playbooks/<area>/<name>.yml`, never deeper. This page defines the areas, the naming
rules, and how to add, move, or retire a playbook.

## Areas

| Folder | Holds | Examples |
|---|---|---|
| `base/` | OS baseline and patching on any host | `apt-hygiene.yml`, `configure-timezone.yml`, `patch-guests.yml` |
| `access/` | SSH CA, root keys, API tokens for access | `configure-ssh-ca.yml`, `mint-pve-audit-token.yml` |
| `backup/` | Backup store, jobs, audits and restore tests | `backup-audit.yml`, `restore-test-backup.yml` |
| `proxmox/` | Nodes, LXC features, mesh, storage, guest lifecycle | `configure-pve-node.yml`, `restart-guests.yml` |
| `media/` | The media stack's hosts and storage | `configure-media-storage.yml` |
| `observability/` | Metrics, logs, audits, inventories, watchdogs | `configure-metrics.yml`, `collect-cve-inventory.yml` |
| `ollama/` | The GPU inference host | `configure-ollama-246.yml`, `ollama-models.yml` |
| `vault/` | Vault on 223 and its snapshots | `configure-vault.yml`, `vault-snapshot.yml` |
| `services/` | One play per service host | `configure-plane.yml`, `configure-pete-bot.yml` |
| `villain/` | Chaos tests (Joker, Thanos). Operator-run only | `joker.yml`, `thanos.yml` |
| `archive/` | Superseded plays kept as a record. Never run | `configure-mesh-vxlan.yml` |

`files/` and `templates/` stay directly under `ansible/playbooks/` and are shared by every area.
They hold assets, not plays. Add a new area only when no row above fits, and add its row here in
the same pull request.

## Rules

1. **Name:** lowercase letters, digits and hyphens, ending in `.yml`. Keep the name when the
   playbook moves, so a search for it still works.
2. **Header:** the first comment lines say what the play does, which hosts it targets, and the
   command that runs it, with the area in the path: `ansible-playbook playbooks/backup/backup-audit.yml`.
3. **Assets:** reach a shared asset with `{{ playbook_dir | dirname }}/files/<x>` or
   `{{ playbook_dir | dirname }}/templates/<x>`. A bare `src: x.j2` fails in an area folder, and a
   `../` path fails the `no-relative-paths` lint rule.
4. **Paths out of the tree:** `{{ playbook_dir }}/../../environments/...` becomes
   `{{ playbook_dir }}/../../../environments/...` one folder deeper. Use
   `scripts/playbook-move.py` instead of editing by hand.
5. **Imports:** `import_playbook` targets are relative to the importing file, for example
   `../ollama/ollama-service.yml`.
6. **Allowlist:** `scripts/lab-playbooks.txt` lists a playbook as `<area>/<name>.yml`. The guard,
   `lab-action.sh` and `lab-playbook.sh` accept that form and nothing deeper. `archive/` and
   `villain/` playbooks never go on the allowlist.
7. **Outside callers:** a playbook that another repo's workflow runs by path stays directly under
   `ansible/playbooks/` until that repo changes its caller. `configure-pete-bot.yml` (pete-bot),
   `configure-media-dash.yml` (petedio-media-control) and `configure-search.yml` (petedio-search)
   are such playbooks. Search the other repos for a playbook's path before you move it.
8. **Stale plays:** a play that targets a retired host, or that a newer play replaced, moves to
   `archive/` with a dated banner that says what replaced it and why it must not run. A play with
   no remaining value is deleted, and the pull request gives a one-line reason. CI still
   syntax-checks and lints `archive/`, so a kept play stays valid YAML.

## Move a playbook

To move playbooks, write a map file with one `<file>.yml <area>` line each and run:

```sh
scripts/playbook-move.py map.txt            # dry run
scripts/playbook-move.py map.txt --apply    # git mv, then rewrite references
```

The script fixes imports, `playbook_dir` depth, shared asset paths, and every reference in
workflows, scripts, docs, inventory and the allowlist. It prints how many files it read, moved
and rewrote. It does not run Ansible. After it, run from `ansible/`:

```sh
for f in $(find playbooks -name '*.yml' -not -path 'playbooks/files/*' -not -path 'playbooks/templates/*'); do
  ansible-playbook --syntax-check "$f" || echo "FAIL $f"
done
../scripts/lab-playbook-guard.py --all
```

A moved playbook changes the path that `ansible-validate.yml` examines and, for deploy
workflows, the file their `paths:` filters watch. Review those workflow diffs by hand.
