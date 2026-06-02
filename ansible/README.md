<!-- Ported from homelab-infra for the greenfield petedio-iac. Dual-GPU (GTX 1660 SUPER + RTX 3060 Ti), .240. -->
# Ansible — ollama-host

Manages **ollama-host**: an Ubuntu Server 24.04 box (MSI X570-A PRO) running
**native Ollama** (not Docker) across **two GPUs — GTX 1660 SUPER + RTX 3060 Ti**
via a single Ollama service (no GPU pin; Ollama uses both), serving the Ollama
API to the homelab LAN at **`192.168.50.240:11434`**. Brought under IaC the
bare-metal way — Terraform declares the host; Ansible does the OS/service config.

- **NIC:** `eth0`, MAC `2c:f0:5d:a2:7f:4f`, Wake-on-LAN (magic packet) enabled.
- **GPUs:** both cards exposed through one service (no `CUDA_VISIBLE_DEVICES` pin); set `OLLAMA_SCHED_SPREAD=1` in host_vars to force every model across both.
- **Connection:** `ansible_user: ansible`, key `~/.ssh/id_ed25519_pedro`, `become: true`. **No secrets** (no vault/SOPS).
- **Control node:** Mac-local on the LAN. `ansible.cfg` uses **no ProxyJump** by default; pve01 (`.10`) is an optional recovery jump only.

## Layout

```
ansible.cfg
inventory/hosts.yml                 # ollama group -> ollama-host @ .240
inventory/host_vars/ollama-host.yml # NIC/WoL/IP/DNS, base models, GPU env
roles/ollama-service/              # NVIDIA 550, Ollama install, systemd drop-in, UFW, WoL, no-sleep
roles/ollama-models/               # pulls base models (gemma4:e4b)
playbooks/ollama-service.yml
playbooks/ollama-models.yml
playbooks/set-ollama-static-ip.yml      # renumber w/ auto-revert safety
playbooks/wake-ollama-host.yml
playbooks/provision-new-ollama-host.yml # fresh-box bootstrap (keys/hostname/IP)
```

## Running the plays (bootstrap order)

Run from this `ansible/` directory.

1. **(Fresh box only) Provision** — keys, hostname, static IP at `.240` (reboots to apply).
   Point the inventory at the box's current address:
   ```sh
   ansible-playbook playbooks/provision-new-ollama-host.yml -i '<current-ip>,' -e ansible_user=ansible
   ```
   An existing host that just needs the IP changed should use the renumber
   runbook below instead (it is auto-revert safe).

2. **Service** — NVIDIA driver 550 (reboots if newly installed), official Ollama
   installer, `OLLAMA_HOST` systemd drop-in, UFW 11434 from `192.168.50.0/24`,
   WoL `.link`, no-sleep/no-suspend hardening (asserts **both** GPUs are visible):
   ```sh
   ansible-playbook playbooks/ollama-service.yml
   ```

3. **Models** — pull base models (`gemma4:e4b`):
   ```sh
   ansible-playbook playbooks/ollama-models.yml
   ```

**Wake the host** when it is powered off (WoL magic packet):
```sh
ansible-playbook playbooks/wake-ollama-host.yml --tags wait
```

## Renumber runbook: `.59` -> `.240`

> **Manual, gated step — NOT apply-on-merge.** A bad netplan apply can lock the
> box off the network. `set-ollama-static-ip.yml` installs an **auto-revert
> safety**: it backs up the live netplan and arms a detached background timer
> that restores + re-applies the old config after `netplan_revert_seconds`
> (default **180**) **unless cancelled**. The second play reconnects on `.240`
> and cancels the revert automatically; if it never reconnects, the box heals
> itself back to the previous network.

**Pre-checks**
- Host reachable now (at `.59`, or a temporary DHCP address).
- You have a fallback path if SSH drops: **WoL** (`wake-ollama-host.yml`), a
  one-off **pve01 jump** (`-e "ansible_ssh_common_args='-o ProxyJump=pve01'"`),
  or **physical console**.
- Decide the revert window (`-e netplan_revert_seconds=300` for more breathing room).

**Apply (auto-revert safe)**

The inventory now points ollama-host at `.240`, but during the cutover the box is
still at `.59` — so reach it at its CURRENT address via `current_ollama_host`:
```sh
# the .59 -> .240 cutover (box is currently at .59):
ansible-playbook playbooks/set-ollama-static-ip.yml -e current_ollama_host=192.168.50.59
# ...or from any other current/temporary address (e.g. a DHCP lease):
ansible-playbook playbooks/set-ollama-static-ip.yml -e current_ollama_host=192.168.50.X
# once the host is already on .240 (idempotent re-runs), the bare command works:
ansible-playbook playbooks/set-ollama-static-ip.yml
```
The play backs up the current netplan, arms the revert sentinel
(`/run/ollama-netplan-revert.pending`), launches the detached guard, writes the
`.240` config, and applies (SSH will drop). It then reconnects on `.240`,
confirms the address, and **cancels the revert**.

**If you get locked out**
- Do nothing for `netplan_revert_seconds` — the guard restores the old netplan
  and re-applies, bringing `.59` (or the prior address) back. Then investigate.
- To recover sooner, reach the box via **WoL**, the **pve01 jump**, or the
  **physical console** and inspect `/var/log/ollama-netplan-revert.log`.

**Manually cancelling the revert** (if you confirmed `.240` out of band):
```sh
sudo rm -f /run/ollama-netplan-revert.pending   # disarm
sudo pkill -f ollama-netplan-revert.sh          # stop the timer now
```

**Update the router DHCP reservation**
- Change the reservation for MAC **`2c:f0:5d:a2:7f:4f`** to **`192.168.50.240`**
  so the lease and the static config agree.

**Post-checks**
```sh
curl http://192.168.50.240:11434/api/version          # Ollama answering on .240
curl http://192.168.50.240:11434/api/tags             # models intact (gemma4:e4b present)
ssh ansible@192.168.50.240 nvidia-smi                  # both GPUs healthy (1660 SUPER + 3060 Ti)
```
