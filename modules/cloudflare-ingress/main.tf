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

  # Fail-closed: a public CNAME must not exist before its Access gate. If the Access app
  # apply fails (missing Zero Trust org / token scope), no hostname resolves at the edge —
  # better than briefly exposing the origin ungated. Access apps exist only for access=true
  # routes; ordering all CNAMEs after them is harmless for the non-gated ones.
  depends_on = [cloudflare_zero_trust_access_application.route]
}

# Cloudflare Access (optional, per route). The Authentik OIDC IdP referenced by
# allowed_idps is created by PET-38; until then leave access=false on routes.
resource "cloudflare_zero_trust_access_policy" "route" {
  for_each = local.access_routes

  account_id = var.account_id
  name       = "${each.key} — allow"
  decision   = "allow"

  # Precedence: explicit emails (one or more people) > email domain > everyone. Provider v5
  # uses attribute syntax ({ email = { email = ... } }), not v4's nested include {} blocks.
  include = length(each.value.access_emails) > 0 ? [
    for e in each.value.access_emails : { email = { email = e } }
    ] : (
    each.value.access_email_domain != null
    ? [{ email_domain = { domain = each.value.access_email_domain } }]
    : [{ everyone = {} }]
  )
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

  # v5 `policies` is a list of objects (ListNestedAttribute), not bare IDs. A bare-string
  # element passes `terraform validate` (the for_each .id is unknown at validate time) but
  # FAILS the apply plan with "object required, but have string". Use the { id = ... } form.
  policies = [{ id = cloudflare_zero_trust_access_policy.route[each.key].id }]
}
