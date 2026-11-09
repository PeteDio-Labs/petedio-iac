# Emits, from var.routes:
#   - ONE cloudflare_zero_trust_tunnel_cloudflared_config (all ingress rules + 404 catch-all)
#   - a proxied CNAME per hostname -> the tunnel
#   - when access=true: a Cloudflare Access application + policy per route
#
# A route's map key is its name. Its hostname defaults to the key; set `hostname` to put
# several path routes on one hostname (PET-667). Every route that shares a hostname must
# set `path`, and a gated one sets `access_path` so its Access app covers only that path.
# Provider v5 uses attribute syntax (config = { ingress = [...] }), not nested blocks.

locals {
  host_of = { for k, r in var.routes : k => coalesce(r.hostname, k) }

  # cloudflared takes the first matching rule, so on a shared hostname the path rules sort
  # ahead of a path-less one. The sort key is "<hostname> <0|1> <name>". The space sorts
  # below every hostname character, so routes with a unique hostname keep the plain
  # sort(keys) order they had before PET-667, and the tunnel config plans unchanged.
  rule_order = [for s in sort([
    for k, r in var.routes : "${local.host_of[k]} ${r.path == null ? 1 : 0} ${k}"
  ]) : split(" ", s)[2]]

  route_rules = [for k in local.rule_order : {
    hostname = local.host_of[k]
    path     = var.routes[k].path
    service  = var.routes[k].service
    origin_request = {
      http_host_header = local.host_of[k]
      no_tls_verify    = var.routes[k].no_tls_verify
    }
  }]

  # One CNAME per hostname, keyed by the hostname. For a route with no `hostname`, that is
  # its key, so every existing record keeps its address.
  hostnames = toset(values(local.host_of))

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
  agent_routes  = { for h, r in local.access_routes : h => r if length(r.agents) > 0 }

  # The one header an agent sends its service token in (read_service_tokens_from_header).
  agent_token_header = "Cf-Access-Token"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    ingress = local.ingress_rules
  }
}

resource "cloudflare_dns_record" "route" {
  for_each = local.hostnames

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

# The agents' service tokens, by name. keys.yml creates each one as agent-<name>
# (scripts/keys.py). Read only when a route lists agents, so a plan with none never calls the
# service-token API.
data "cloudflare_zero_trust_access_service_tokens" "agents" {
  count      = length(local.agent_routes) > 0 ? 1 : 0
  account_id = var.account_id
  max_items  = 1000
}

locals {
  # Grouped, so two tokens with one name give a list of two ids, not a "Duplicate object key"
  # error that stops every route. The policy's precondition refuses the duplicate by name.
  agent_token_id_lists = length(local.agent_routes) == 0 ? {} : {
    for t in data.cloudflare_zero_trust_access_service_tokens.agents[0].result :
    trimprefix(t.name, "agent-") => t.id... if startswith(t.name, "agent-")
  }
  agent_token_ids = { for n, ids in local.agent_token_id_lists : n => ids[0] if length(ids) == 1 }
}

# Service Auth for agents: a non_identity policy matches a service token, never a person. A
# route gets one only when it lists agents, so every other route plans unchanged.
resource "cloudflare_zero_trust_access_policy" "route_agents" {
  for_each = local.agent_routes

  account_id = var.account_id
  name       = "${each.key} — agents"
  decision   = "non_identity"
  include    = [for a in each.value.agents : { service_token = { token_id = lookup(local.agent_token_ids, a, "") } }]

  lifecycle {
    precondition {
      condition     = alltrue([for a in each.value.agents : length(lookup(local.agent_token_id_lists, a, [])) <= 1])
      error_message = "Cloudflare holds more than one agent-<name> token for an agent on this route. Delete the extra one under Access > Service credentials, then run keys.yml action=sync."
    }
    precondition {
      condition     = alltrue([for a in each.value.agents : contains(keys(local.agent_token_ids), a)])
      error_message = "A route lists an agent with no service token. Add it to secrets/callers.yml and run keys.yml action=sync first."
    }
  }
}

resource "cloudflare_zero_trust_access_application" "route" {
  for_each = local.access_routes

  zone_id                   = var.zone_id
  name                      = each.key
  domain                    = "${local.host_of[each.key]}${each.value.access_path == null ? "" : each.value.access_path}"
  type                      = "self_hosted"
  session_duration          = each.value.session_duration
  allowed_idps              = each.value.allowed_idps
  auto_redirect_to_identity = length(each.value.allowed_idps) > 0

  # v5 `policies` is a list of objects (ListNestedAttribute), not bare IDs. A bare-string
  # element passes `terraform validate` (the for_each .id is unknown at validate time) but
  # FAILS the apply plan with "object required, but have string". Use the { id = ... } form.
  policies = concat(
    [{ id = cloudflare_zero_trust_access_policy.route[each.key].id }],
    contains(keys(local.agent_routes), each.key) ? [{ id = cloudflare_zero_trust_access_policy.route_agents[each.key].id }] : [],
  )

  # Agents send their service token as one JSON header, because Muse can send only one custom
  # header (2026-11-09). A refused agent gets a 401, not a redirect to the login page. Both stay
  # null on a route with no agents, so those apps plan unchanged.
  read_service_tokens_from_header = contains(keys(local.agent_routes), each.key) ? local.agent_token_header : null
  service_auth_401_redirect       = contains(keys(local.agent_routes), each.key) ? true : null

  # Managed OAuth (PET-292). Present only for routes that asked for it, so every
  # existing app keeps oauth_configuration unset and plans clean.
  #
  # Dynamic client registration is enabled here because that is how the MCP client
  # obtains a client_id: it registers itself against Access. `allowed_uris` is the
  # security boundary on that — only these redirect targets can be registered, so
  # keep it to the exact client callbacks, never a wildcard host.
  oauth_configuration = each.value.managed_oauth == null ? null : {
    enabled = each.value.managed_oauth.enabled

    dynamic_client_registration = {
      enabled                = true
      allowed_uris           = each.value.managed_oauth.allowed_redirect_uris
      allow_any_on_localhost = false
      allow_any_on_loopback  = each.value.managed_oauth.allow_any_on_loopback
    }

    grant = {
      access_token_lifetime = each.value.managed_oauth.access_token_lifetime
      session_duration      = each.value.managed_oauth.session_duration
    }
  }
}
