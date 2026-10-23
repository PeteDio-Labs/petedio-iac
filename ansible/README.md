<!-- Ported from homelab-infra for the greenfield petedio-iac. Dual-GPU (GTX 1660 SUPER + RTX 3060 Ti), LXC 246 on pve01 since PET-528. -->
# Ansible — host-level config for every guest, and the GPU inference host

`ansible/` holds the inventory, playbooks and roles for the whole lab, one playbook per
concern. The runbook for a given host is the header comment of its
`playbooks/configure-<name>.yml`; `docs/GOTCHAS.md` holds the traps. This file also
describes the GPU inference host, ollama-246, below.

## ollama-246

An LXC on the Proxmox node **pve01** (`.12`), at **`192.168.50.246`**, running **native
Ollama** on **two GPUs — GTX 1660 SUPER + RTX 3060 Ti** — as **two pinned services**:
`ollama` on `:11434` pinned to the 3060 Ti, and `ollama-1660s` on `:11435` pinned to the
1660 SUPER (`roles/ollama-service/defaults`). petedio-search runs beside them on `:8526`.

Until 2026-10-23 this was bare metal: ollama-host, Ubuntu Server 24.04 at `.12`. `PET-528`
reinstalled that box as pve01 and moved the services into this container. The cutover is
`docs/runbooks/pve01-cutover.md`.

- **GPUs:** pve01 loads the NVIDIA kernel module; the container gets the device nodes
  (`roles/lxc-gpu`) and the matching userspace (`roles/nvidia-driver`, `container` mode).
  Both sides install one pinned `.run` version, so no package upgrade can split them
  (`PET-762`). Each instance is pinned with `CUDA_VISIBLE_DEVICES` to one card's stable
  UUID (`host_vars/ollama-246.yml`).
- **Connection:** `root` over `~/.ssh/id_ed25519_ansible`, the key Terraform installs.
  **No secrets** for the Ollama plays. petedio-search's secrets come from Vault through
  `scripts/deploy-search.sh`.

## Layout

```
inventory/pve01.yml                  # the node
inventory/hosts.yml                  # ollama group -> ollama-246 @ .246
inventory/host_vars/ollama-246.yml   # base models, GPU pins, lane env
roles/nvidia-driver/                 # pinned .run driver: host (DKMS) or container (userspace)
roles/lxc-gpu/                       # devN passthrough of the NVIDIA nodes
roles/ollama-service/                # Ollama install, systemd drop-in, pinned extra lanes
roles/ollama-models/                 # pulls base models and keeps the resident ones loaded
playbooks/configure-pve01.yml        # node: repos, driver, template, GPU passthrough
playbooks/configure-ollama-246.yml   # container: driver userspace, then the two plays below
playbooks/ollama-service.yml
playbooks/ollama-models.yml
playbooks/wake-ollama-host.yml       # WoL for pve01 (same MAC and address)
```

## Running the plays (bootstrap order)

Run from this `ansible/` directory, in the order `docs/runbooks/pve01-cutover.md` gives:

```sh
ansible-playbook playbooks/configure-pve01.yml -e nvidia_driver_allow_reboot=true
ansible-playbook playbooks/configure-ollama-246.yml
```

**Wake the node** when it is powered off (WoL magic packet):
```sh
ansible-playbook playbooks/wake-ollama-host.yml --tags wait
```
