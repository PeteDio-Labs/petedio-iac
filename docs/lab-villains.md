# Lab Villains

Lab Villains break decoy containers on purpose, so you learn whether detection and recovery
work. Each villain has its own universe of decoys. No real service is a target.

| Villain | Universe | Strike | Playbook |
|---|---|---|---|
| Joker | `dc`, VMIDs 250 to 253 | one random fault on one decoy: stop, restart, or stop sshd | `ansible/playbooks/villain/joker.yml` |
| Thanos | `marvel`, VMIDs 210 to 213 | stops half the decoys, rounded down, never the last | `ansible/playbooks/villain/thanos.yml` |

## Safety rules

- `scripts/villain/targets.txt` is the allowlist. `scripts/villain/guard.py` also refuses a
  denylisted VMID, a tier other than `decoy`, an empty list, and the 02:15 to 03:30 Eastern backup window.
- Each play checks that the container's hostname is `decoy-<group>-<vmid>` on its node before it acts.
- A strike arms a systemd timer on the node first. The timer runs `villain-undo` after
  `villain_deadman_minutes` (15), even if the runner dies.
- A strike refuses unless you pass `-e villain_enabled=true`.
- Vault 223 and Authentik 119 are on the denylist and never join a group.
- The playbooks are not on `scripts/lab-playbooks.txt`. Adding them is a trust-boundary change
  that needs Pedro's approval in plain words.

## Run order

1. `ansible-playbook playbooks/villain/joker.yml --check` prints the pick and touches nothing.
2. After Pedro's go, run it with `-e villain_enabled=true`. Note the start time.
3. Run `ansible-playbook playbooks/villain/joker.yml -e villain_undo=true` to put every decoy back now.
4. Run `scripts/villain/scorecard.py --since <start> --victims <vmids> --undo-at <time>`. It reads
   Kuma and exits non-zero when a victim was never seen down.

Kuma checks each decoy on port 22 (`decoy-<group>-<vmid>`). To add them, a host session runs
`scripts/deploy-uptime-kuma.sh` after the merge. Discord is not read by the scorecard; pass `--discord`.

Round two, not built: Bane (capped synthetic load on one decoy) and Ultron (disk and memory exhaustion on a decoy).
