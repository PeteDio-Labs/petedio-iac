# cloudflare-ingress — the URL factory (PET-35)

Turn a **route map** into Cloudflare Tunnel ingress + proxied DNS (+ optional Access gating).
Adding a public, SSO-gated URL becomes: add one map entry → validate on PR → plan and apply on merge.

## Usage

```hcl
module "ingress" {
  source = "../../modules/cloudflare-ingress"

  account_id   = local.cloudflare_account_id
  zone_id      = local.cloudflare_zone_id
  tunnel_id    = local.cloudflare_tunnel_id
  tunnel_cname = data.cloudflare_zero_trust_tunnel_cloudflared.main.cname

  routes = {
    "seer.pdlab.dev" = {
      service = "http://192.168.50.33:5055"          # Overseerr
    }
    "auth.pdlab.dev" = {                             # Authentik
      service             = "http://192.168.50.119:9000"
      access              = true
      allowed_idps        = [var.authentik_idp_id]   # from PET-38
      access_email_domain = "pdlab.dev"
    }
  }
}
```

## What it emits (per the map)

- **One** `cloudflare_zero_trust_tunnel_cloudflared_config` with an ingress rule per route + a
  trailing `http_status:404` catch-all (v5 attribute syntax: `config = { ingress = [...] }`).
- A **proxied** `cloudflare_dns_record` CNAME per hostname → the tunnel (`<id>.cfargotunnel.com`).
- When `access = true`: a `cloudflare_zero_trust_access_application` + `cloudflare_zero_trust_access_policy`
  per route, over its hostname plus `access_path`. The Authentik OIDC IdP referenced by `allowed_idps` is provisioned by **PET-38** —
  keep `access = false` on a route until that IdP exists.

## Route options

| key | required | default | notes |
|---|---|---|---|
| `service` | yes | — | origin URL, e.g. `http://192.168.50.230:80` |
| `hostname` | no | the map key | public hostname. Set it to put several path routes on one hostname (PET-667) |
| `path` | no | `null` | path-scoped ingress rule, a regex. Required on every route that shares a hostname |
| `access_path` | no | `null` | literal path the Access app covers, such as `/mcp/plane`. Required on a gated route that shares a hostname |
| `no_tls_verify` | no | `false` | set true for self-signed origins (e.g. Vault) |
| `access` | no | `false` | gate via Cloudflare Access (needs an IdP) |
| `allowed_idps` | no | `[]` | Access IdP IDs (Authentik, from PET-38) |
| `access_email_domain` | no | `null` | Access policy: allow this email domain |
| `session_duration` | no | `24h` | Access session length |

Origins are plain-HTTP / self-signed on the LAN, so set `no_tls_verify` accordingly.
