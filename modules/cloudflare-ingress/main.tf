# Emits, from var.routes:
#   - ONE cloudflare_zero_trust_tunnel_cloudflared_config (all ingress rules + 404 catch-all)
#   - a proxied CNAME per hostname -> the tunnel
#   - when access=true: a Cloudflare Access application + policy per hostname
# Provider v5 uses attribute syntax (config = { ingress = [...] }), not nested blocks.

locals {
  hosts = sort(keys(var.routes)) # stable ordering for the ingress list

  route_rules = [for h in local.hosts : {
    hostname = h
    path     = var.routes[h].path
    service  = var.routes[h].service
    origin_request = {
      http_host_header = h
      no_tls_verify    = var.routes[h].no_tls_verify
    }
  }]

  # Required trailing catch-all. Same object shape as route_rules (nulls where N/A) so
  # the list element type unifies.
  catch_all = {
    hostname       = null
    path           = null
    service        = "http_status:404"
    origin_request = null
  }

  ingress_rules = concat(local.route_rules, [local.catch_all])

  access_routes = { for h, r in var.routes : h => r if r.access }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    ingress = local.ingress_rules
  }
}

resource "cloudflare_dns_record" "route" {
  for_each = var.routes

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = var.tunnel_cname
  proxied = true
  ttl     = 1 # required to be 1 (automatic) when proxied
}

# Cloudflare Access (optional, per route). The Authentik OIDC IdP referenced by
# allowed_idps is created by PET-38; until then leave access=false on routes.
resource "cloudflare_zero_trust_access_policy" "route" {
  for_each = local.access_routes

  account_id = var.account_id
  name       = "${each.key} — allow"
  decision   = "allow"

  include = [
    each.value.access_email_domain != null
    ? { email_domain = { domain = each.value.access_email_domain } }
    : { everyone = {} }
  ]
}

resource "cloudflare_zero_trust_access_application" "route" {
  for_each = local.access_routes

  zone_id                   = var.zone_id
  name                      = each.key
  domain                    = each.key
  type                      = "self_hosted"
  session_duration          = each.value.session_duration
  allowed_idps              = each.value.allowed_idps
  auto_redirect_to_identity = length(each.value.allowed_idps) > 0

  policies = [cloudflare_zero_trust_access_policy.route[each.key].id]
}
