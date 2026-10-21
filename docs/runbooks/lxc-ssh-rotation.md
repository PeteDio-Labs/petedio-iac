# Rotate the lxc-ssh key (PET-729)

`kv/iac/lxc-ssh` holds the key pair that every Terraform LXC trusts for root. To rotate it
without replacing a container, run `scripts/rotate-lxc-ssh.sh` on the Mac.

## Why a rotation does not replace containers

`modules/proxmox-lxc/main.tf` sets `keys = [trimspace(var.ssh_public_key)]` in
`initialization`, and lists `initialization[0].user_account` in `ignore_changes`. The new public
key that Terraform reads from Vault shows up as no diff. To confirm, run a local
`terraform plan` after the rotation and check that it replaces nothing.

## Run it

1. Run `./scripts/rotate-lxc-ssh.sh --check`. It lists the containers that trust the key and
   changes nothing. It also tries the old private key on every container that does not list
   it, and fails if one still logs in.
2. Run `./scripts/rotate-lxc-ssh.sh`. It needs a Vault token with write access to
   `kv/iac/lxc-ssh` (`$VAULT_TOKEN` or the Keychain item) and the root key for pve02 and pve03.
3. Read the last line. It names how many containers it examined and rotated.

The script appends the new key, proves it logs in everywhere, writes Vault, removes the old key,
then proves the old private key gets `Permission denied`. A stopped container stops the run before any change. If a
run fails after Vault changes, re-run it: Vault's `previous_public_key` field lets it resume
(it cannot test the old private key then, and says so).

## What it does not reach

VMs, bare-metal hosts, and any container that trusts the key from a file other than
`/root/.ssh/authorized_keys`. CI reads the key from Vault at run time, so it needs no change.
The script overwrites `~/.ssh/id_ed25519_ansible` without a backup. Delete other copies of the old private key.
