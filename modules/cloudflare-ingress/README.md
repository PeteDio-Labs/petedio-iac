# cloudflare-ingress — the URL factory (PET-35)

Turn a **route map** into Cloudflare Tunnel ingress + proxied DNS (+ optional Access gating).
Adding a public, SSO-gated URL becomes: add one map entry → plan-on-PR → apply.

## Usage

```hcl
module "ingress" {
  source = "../../modules/cloudflare-ingress"

  account_id   = local.cloudflare_account_id
  zone_id      = local.cloudflare_zone_id
  tunnel_id    = local.cloudflare_tunnel_id
  tunnel_cname = data.cloudflare_zero_trust_tunnel_cloudflared.main.cname

  routes = {
    "co-latro.pdlab.dev" = {
      service = "http://192.168.50.230:80"          # VM-230 nginx (PET-58)
    }
    "admin.pdlab.dev" = {                            # the admin UI (PET-87)
      service             = "http://192.168.50.241:8080" # or the nginx origin fronting MinIO + /fn
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
  per hostname. The Authentik OIDC IdP referenced by `allowed_idps` is provisioned by **PET-38** —
  keep `access = false` on a route until that IdP exists.

## Route options

| key | required | default | notes |
|---|---|---|---|
| `service` | yes | — | origin URL, e.g. `http://192.168.50.230:80` |
| `path` | no | `null` | path-scoped ingress rule |
| `no_tls_verify` | no | `false` | set true for self-signed origins (e.g. Vault) |
| `access` | no | `false` | gate via Cloudflare Access (needs an IdP) |
| `allowed_idps` | no | `[]` | Access IdP IDs (Authentik, from PET-38) |
| `access_email_domain` | no | `null` | Access policy: allow this email domain |
| `session_duration` | no | `24h` | Access session length |

Origins are plain-HTTP / self-signed on the LAN, so set `no_tls_verify` accordingly.
