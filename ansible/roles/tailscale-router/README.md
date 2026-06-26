# tailscale-router (LXC 244)

Turns LXC 244 into a **Tailscale subnet router** that advertises the homelab LAN
(`192.168.50.0/24`) into the tailnet. Once it's up and the route is approved, any
Tailscale client (phone, laptop) can reach every homelab service by its `192.168.50.x`
address — no per-host Tailscale install, no port-forwarding, no exposed ports.

## What's automated vs. what you do by hand

| Step | Owner |
|---|---|
| Create the LXC (hardware, network, SSH key) | **Terraform** — `environments/homelab/tailscale.tf`, applied on merge |
| Add `/dev/net/tun` to the unprivileged LXC | **Operator** — `scripts/lxc-tun-244.sh` (root@pam on the node; API tokens can't) |
| Install tailscale + enable IP forwarding | **Ansible** — this role |
| `tailscale up --advertise-routes=…` | **Ansible** — this role, *when given an auth key* |
| Mint the auth key | **You**, in the Tailscale admin console |
| **Approve the advertised route** | **You**, in the Tailscale admin console |
| Toggle "use subnet routes" on each client | **You**, in the client app |

## Runbook (post-merge)

1. **Confirm the LXC exists** (apply-on-merge created it):
   ```sh
   ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 "pct status 244"
   ```

2. **Add the TUN device** (on the node, out-of-band — see the script header for why):
   ```sh
   ./scripts/lxc-tun-244.sh
   ```

3. **Mint an auth key** at https://login.tailscale.com/admin/settings/keys
   (Reusable; tag it e.g. `tag:subnet-router` if you use ACL tags). Store it in Vault:
   ```sh
   vault kv put kv/services/tailscale auth_key=tskey-auth-XXXXXX
   ```

4. **Run the play** (pulls the key from Vault, no secret on disk):
   ```sh
   cd ansible/playbooks
   ansible-playbook -i ../inventory/hosts.yml configure-tailscale.yml \
     -e "tailscale_auth_key=$(vault kv get -field=auth_key kv/services/tailscale)"
   ```

5. **Approve the route** — https://login.tailscale.com/admin/machines → `tailscale-244`
   → **Edit route settings** → enable `192.168.50.0/24`. (Routes are *not* live until
   approved here, even though the node advertised them.) Optionally disable key expiry on
   this machine so the router doesn't drop off the tailnet.

6. **On your client** (phone/laptop Tailscale app) enable **Use Tailscale subnet routes**.
   Then hit any homelab service by its LAN IP — e.g. your radar at its `192.168.50.x`.

## Notes
- IP forwarding (`net.ipv4.ip_forward`, `net.ipv6.conf.all.forwarding`) is set by this
  role via `/etc/sysctl.d/99-tailscale.conf`.
- The role is safe to run **before** the key exists — it installs everything and only
  skips `tailscale up`, printing a reminder.
- No secrets live in the repo; the auth key is Vault-only (`kv/services/tailscale`).
