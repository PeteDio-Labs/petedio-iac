# Runbook — Palworld cutover: LXC 234 → baremetal `palworld-mc` (PET-266)

Moves the live Palworld world from the Proxmox container to the ex-mission-control laptop
(Pop!_OS 24.04) wired into the `.86` play segment. The laptop **takes over the LXC's mesh
address `192.168.86.234`**, so no player has to re-enter a server IP — the move is invisible
from a game client.

Prereq: PR "support a baremetal game host" is merged and `palworld-mc` has converged
(server binaries installed, unit enabled, panel deployed and answering on `:8080`).

---

## The trap that dictates the order

`modules/proxmox-lxc` sets **`started = var.start_on_boot`**. So a container stopped by hand
(`pct stop 234`) is *drift*, and the next `terraform apply` on the homelab root — which any
merge to `main` can trigger — will **boot it back up**. A revived 234 re-grabs
`192.168.86.234`, which by then belongs to the laptop → **address conflict on the segment
the family plays on**.

So the LXC is stopped **declaratively, and that merge lands before the laptop is
re-addressed**. Never leave a hand-stopped 234 sitting in front of an apply.

---

## Phase 1 — take the LXC down declaratively

1. Check who is on: `GET /api/status` on the panel, or

   ```bash
   ssh root@192.168.50.234 'PW=$(grep -o "AdminPassword=\"[^\"]*\"" /home/steam/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini | cut -d\" -f2); curl -su admin:$PW http://127.0.0.1:8212/v1/api/players'
   ```

2. Warn the players, then stop. Use the panel's countdown (it broadcasts at milestones), or
   drive REST directly — announce, flush, shut down:

   ```bash
   ssh root@192.168.50.234 'PW=$(grep -o "AdminPassword=\"[^\"]*\"" /home/steam/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini | cut -d\" -f2); \
     curl -su admin:$PW -H "Content-Type: application/json" -d "{\"message\":\"Server is moving to a new machine - back in about 5 minutes\"}" http://127.0.0.1:8212/v1/api/announce; \
     sleep 30; \
     curl -su admin:$PW -H "Content-Type: application/json" -d "" http://127.0.0.1:8212/v1/api/save; \
     systemctl stop palworld'
   ```

   `TimeoutStopSec=30` in the unit gives the server room to flush rather than getting
   SIGKILLed. Confirm it is really down before copying anything.

3. **Final backup** — the world as of this moment, not the one taken earlier. Same shape as
   the pre-move capture: flush, `tar -czf` the `Pal/Saved` tree plus the host control files,
   `sha256sum`, and push to MinIO `palworld-backups/`.

4. Merge a PR setting `start_on_boot = false` on the `palworld` module in
   `environments/homelab/palworld.tf`. Apply-on-merge stops the container **and** records
   that it should stay stopped. Verify: `pct status 234` → `stopped`, and
   `ping 192.168.86.234` → no reply (the address is now free).

## Phase 2 — carry the world across

5. Stop the throwaway world on the laptop and replace its saves with the real ones:

   ```bash
   ssh root@192.168.86.123 'systemctl stop palworld'
   ssh root@192.168.86.123 'rm -rf /home/steam/palworld/Pal/Saved/SaveGames'
   rsync -aH --info=progress2 \
     root@192.168.50.234:/home/steam/palworld/Pal/Saved/SaveGames/ \
     root@192.168.86.123:/home/steam/palworld/Pal/Saved/SaveGames/
   ssh root@192.168.86.123 'chown -R steam:steam /home/steam/palworld/Pal/Saved'
   ```

   Only `SaveGames/` moves. `PalWorldSettings.ini` stays the Ansible-managed one already on
   the laptop — same values, same `AdminPassword`, so the panel and REST keep working.

## Phase 3 — take the address

6. Re-address the laptop to the LXC's freed address. This drops your SSH session, so detach
   it from the connection or the reconfigure dies halfway:

   ```bash
   ssh root@192.168.86.123 'systemd-run --on-active=3 --unit=palworld-reip \
     nmcli con mod "Wired connection 1" ipv4.addresses 192.168.86.234/24'
   ```

   Then re-apply the connection and confirm from a fresh session:
   `ping 192.168.86.234` and `ssh root@192.168.86.234 'hostname'` → `mission-control`.
   Reserve/exclude `.234` for MAC `9c:69:d3:14:0f:0c` on the `.86` router. Note the NIC is a
   **USB adapter** (`enx9c69d3140f0c`) — its name and MAC come from the dongle, so swapping
   it breaks both the interface name and any MAC reservation.

7. Start the game server and prove the world came across intact — not just that it booted:

   ```bash
   ssh root@192.168.86.234 'systemctl start palworld'
   # then, once /info answers:
   #   worldguid must equal 0BA20FE97DF7472AADFD2237B5B4EFFC
   #   metrics.days must be >= the value recorded before the move
   #   metrics.basecampnum must match (7 at the time of writing)
   ```

## Phase 4 — repoint the edge, then retire

8. Merge the cutover PR: `ansible_host` for `palworld-mc` → `192.168.86.234`, and
   `cloudflare-routes.tf` `palworld.pdlab.dev` service → `http://192.168.86.234:8080`.
   Verify `https://palworld.pdlab.dev` returns `302` to the Access login and that the panel
   loads and shows the live world.

9. Have a player connect and confirm their saved server entry still works untouched.

10. Leave 234 **stopped but intact** for a few days as the rollback. Then retire it: delete
    `environments/homelab/palworld.tf`, drop `palworld-234` from the inventory, and let
    apply-on-merge destroy the container.

---

## Rollback (while 234 still exists)

The two servers cannot both hold `192.168.86.234`. To go back: stop `palworld` on the
laptop and return it to `192.168.86.123`, set `start_on_boot = true` on the palworld module
and merge (TF boots the container and it reclaims `.234`), then point the Cloudflare route
back at `http://192.168.50.234:8080`. Anything the family played on the laptop after the
cutover stays in the laptop's `SaveGames/` — copy it back first if it matters.
