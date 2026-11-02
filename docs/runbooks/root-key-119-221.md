# Restore root key access on LXC 119 and 221 (PET-787)

`playbooks/configure-root-key.yml` appends the inventory identity's public key to
`/root/.ssh/authorized_keys` on authentik-119 and minio-221. Both refused it on 2026-11-02, so
`collect-cve-inventory.yml` read 25 of 27 hosts.

## Why the key was missing

The `proxmox-lxc` module installs the key at creation. 221 is hand-managed and 119 was captured
into Terraform after it existed, so neither received it. The inventory entries already name root
and `~/.ssh/id_ed25519_ansible`, so the collector's connection vars need no change.

## Run it

From the Mac or 247, with root SSH to pve03:

1. Run `cd ansible && ansible-playbook playbooks/configure-root-key.yml --check`.
2. Run `ansible-playbook playbooks/configure-root-key.yml`.
3. Read the last task: it names how many guests the nodes examined and which.
4. Run `ansible-playbook playbooks/collect-cve-inventory.yml` with no extra vars and confirm 27 of 27.

The play reaches each guest with `pct exec` on its node, derives the public key with
`ssh-keygen -y` (override with `-e lxc_root_key_public=...`), and appends it once. It reads the
file and `sshd -T` `permitrootlogin` back, and fails if the key is absent or root login is `no`.
A listed guest that no node holds, or a stopped guest, fails the run.
