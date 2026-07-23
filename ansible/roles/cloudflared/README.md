# cloudflared

Runs a Cloudflare tunnel **connector** on a host, so an origin on that host can bind
**loopback only** and still be reachable at a public hostname (PET-266).

The connector is **token-managed**: ingress rules live in Cloudflare and are owned by
Terraform (`environments/homelab/cloudflare-routes.tf`), not by a config file on the box.
This role installs the daemon and hands it the token — it never writes ingress config.

## Why a host gets its own connector

A tunnel's ingress config applies to **every connector on that tunnel**. A rule pointing at
`http://127.0.0.1:8080` therefore only makes sense if every connector on the tunnel has that
origin — so a loopback origin needs its **own tunnel**, with its connector on the origin host.
See the `module.cloudflare_ingress_palworld` comment in `cloudflare-routes.tf`.

## Variables

| Var | Default | Notes |
| -- | -- | -- |
| `cloudflared_tunnel_token` | *(none)* | **Secret.** From Vault at runtime. Without it the daemon installs but no connector is registered. |
| `cloudflared_apt_release` | `ansible_distribution_release` | Cloudflare publishes per-codename lists. Pop!_OS 24.04 → `noble`. |

## Token rotation

`cloudflared service install` bakes the token into the systemd unit and refuses to run when a
service already exists, so this role skips it once `/etc/systemd/system/cloudflared.service`
is present. To rotate:

```bash
sudo cloudflared service uninstall
```

then re-run the play with the new token.

## Used by

`ansible/playbooks/configure-palworld-tunnel.yml` — the connector for `palworld.pdlab.dev`
on `palworld-mc`.
