# Restore collector access to LXC 119 and 221 (PET-787, PET-793)

`playbooks/configure-root-key.yml` appends the inventory identity's public key to
`/root/.ssh/authorized_keys` on authentik-119 and minio-221. Both refused it on 2026-11-02, so
`collect-cve-inventory.yml` read 25 of 27 hosts.

## Why the key was missing

The `proxmox-lxc` module installs the key at creation. 221 is hand-managed and 119 was captured
into Terraform after it existed, so neither received it. The inventory entries already name root
and `~/.ssh/id_ed25519_ansible`, so the collector's connection vars need no change.

## Run it

Authentik-119 and minio-221 both live on pve03, so the play changes only that node. It checks every node in `proxmox:pve_new:pve_gpu` for the listed guests. Run it from the Mac or 247 with root SSH to the nodes. `--check` reads which node holds each guest, derives the key and confirms each guest is running. It does not read `authorized_keys` or `sshd`, so it cannot say whether the key is already installed. The real run does, and fails if the key or root login is missing afterwards.

1. Run `cd ansible && ansible-playbook playbooks/configure-root-key.yml --check`.
2. Run `ansible-playbook playbooks/configure-root-key.yml`.
3. Read the last task: it names how many guests the nodes examined and which.
4. Run `ansible-playbook playbooks/collect-cve-inventory.yml` with no extra vars and confirm 27 of 27.

The play reaches each guest with `pct exec` on its node, derives the public key with
`ssh-keygen -y` (override with `-e lxc_root_key_public=...`), and appends it once. It reads the
file and `sshd -T` `permitrootlogin` back, and fails if the key is absent or root login is `no`.
A listed guest that no node holds, or a stopped guest, fails the run.

## 119 is reached through its node (PET-793)

Authentik-119 sets `PermitRootLogin no`, and that setting stays. `playbooks/configure-root-key.yml`
lists only 221, because it fails a guest whose root login is `no`. The inventory connects to 119
with `community.proxmox.proxmox_pct_remote`: it opens SSH to pve03 (`192.168.50.10`) as root and
runs each command with `pct exec 119`. No key goes into 119.

To run the collector, the controller needs the `paramiko` Python package and the collection:

1. Run `pip install paramiko`.
2. Run `ansible-galaxy collection install -r ansible/requirements.yml`.
3. Run `ansible-playbook playbooks/collect-cve-inventory.yml` and confirm 27 of 27.

The controller needs root SSH to pve03, so run the collector from the Mac or a host with node access.
