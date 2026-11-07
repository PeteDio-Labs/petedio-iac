# PET-839 — one Cloudflare MCP server portal in front of the Plane and lab MCP servers.
#
# A portal gives an MCP client a single connector URL for both servers. The per-hostname
# Access applications in cloudflare-routes.tf stay in place, so the direct URLs keep working
# and the portal is removable without losing access. Schema checked against provider 5.21.1
# on 2026-11-06 (PET-839 comment 1d235af7). Plan tier: Free (Pedro, 2026-11-06).
#
# Only Pedro's servers are listed. mcp-tom and mcp-sonia stay direct, because a portal's
# access policy is per portal and each of those servers acts as one other person.
#
# What the first apply showed (PET-839 comments e5b8cbd1 and f6f40c22):
#   - The API creates no DNS record for the portal hostname, so this file declares one.
#   - The portal and the servers carry no policy attribute. A policy attaches through an Access
#     application of type mcp_portal (the portal) or mcp (each server), so this file declares both.
#   - A server shows "Waiting" until an admin runs "Save and connect server" in the Zero Trust
#     dashboard. That signs in as Pedro, so Terraform cannot do it.

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "plane" {
  account_id  = local.cloudflare_account_id
  id          = "plane"
  name        = "Plane"
  description = "PeteDio Plane work items (PET-839)."
  hostname    = "https://mcp-plane.pdlab.dev/mcp"
  auth_type   = "oauth"

  # Set explicitly, never unset. An unset value plans as `false -> null`, the PUT sends null,
  # and the API rejects it with 400 "Expected boolean, received null" (PET-839, #630).
  # true makes portal users sign in to the upstream through one fixed Cloudflare-hosted
  # callback, in place of the per-user portal callback. It does not change the administrator
  # sign-in: "Authenticate server" in the dashboard still redirects to the per-server dashboard
  # callback (.../ai-controls/mcp-server/oauth-callback/<id>). The upstream's
  # managed_oauth.allowed_redirect_uris in cloudflare-routes.tf needs both the hosted URL and
  # the two per-server dashboard URLs (per Cloudflare's MCP portal docs; unverified here).
  is_shared_oauth_callback_enabled = true
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "lab" {
  account_id  = local.cloudflare_account_id
  id          = "lab"
  name        = "Lab"
  description = "Read-only homelab state (PET-839)."
  hostname    = "https://mcp-lab.pdlab.dev/mcp/lab"
  auth_type   = "oauth"

  # Set explicitly, never unset. An unset value plans as `false -> null`, the PUT sends null,
  # and the API rejects it with 400 "Expected boolean, received null" (PET-839, #630).
  # true makes portal users sign in to the upstream through one fixed Cloudflare-hosted
  # callback, in place of the per-user portal callback. It does not change the administrator
  # sign-in: "Authenticate server" in the dashboard still redirects to the per-server dashboard
  # callback (.../ai-controls/mcp-server/oauth-callback/<id>). The upstream's
  # managed_oauth.allowed_redirect_uris in cloudflare-routes.tf needs both the hosted URL and
  # the two per-server dashboard URLs (per Cloudflare's MCP portal docs; unverified here).
  is_shared_oauth_callback_enabled = true
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_portal" "pdlab" {
  account_id  = local.cloudflare_account_id
  id          = "pdlab"
  name        = "PeteDio lab"
  description = "Plane and lab MCP servers behind one URL (PET-839)."
  hostname    = "mcp.pdlab.dev"

  # Off on purpose. The beta runs remote code in Dynamic Workers, and the provider defaults
  # it to true. Pedro turns it on in a later change if he wants it.
  allow_code_mode = false

  servers = [
    { server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.plane.id },
    { server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.lab.id },
  ]
}

# Who may use the portal and see each server: Pedro alone, like mcp-plane and mcp-lab in
# cloudflare-routes.tf. The include list is the whole authorization boundary.
resource "cloudflare_zero_trust_access_policy" "mcp_portal" {
  account_id = local.cloudflare_account_id
  name       = "mcp.pdlab.dev - allow Pedro"
  decision   = "allow"
  include    = [{ email = { email = "pedelgadillo@gmail.com" } }]
}

resource "cloudflare_zero_trust_access_application" "mcp_server" {
  for_each = {
    plane = cloudflare_zero_trust_access_ai_controls_mcp_server.plane.id
    lab   = cloudflare_zero_trust_access_ai_controls_mcp_server.lab.id
  }

  account_id   = local.cloudflare_account_id
  name         = "mcp server ${each.key}"
  type         = "mcp"
  destinations = [{ type = "via_mcp_server_portal", mcp_server_id = each.value }]
  policies     = [{ id = cloudflare_zero_trust_access_policy.mcp_portal.id }]
}

resource "cloudflare_zero_trust_access_application" "mcp_portal" {
  account_id = local.cloudflare_account_id
  name       = "mcp.pdlab.dev"
  type       = "mcp_portal"
  domain     = "mcp.pdlab.dev"
  policies   = [{ id = cloudflare_zero_trust_access_policy.mcp_portal.id }]
}

# The portal hostname resolves to Cloudflare's MCP gateway, proxied. It waits for the Access
# applications, so the name never resolves before its gate exists (the fail-closed rule in
# modules/cloudflare-ingress).
resource "cloudflare_dns_record" "mcp_portal" {
  zone_id = local.cloudflare_zone_id
  name    = "mcp.pdlab.dev"
  type    = "CNAME"
  content = "gateway.agents.cloudflare.com"
  ttl     = 1 # automatic, required when proxied
  proxied = true
  comment = "MCP server portal (PET-839). Gated by the mcp_portal Access application."

  depends_on = [
    cloudflare_zero_trust_access_application.mcp_portal,
    cloudflare_zero_trust_access_application.mcp_server,
  ]
}
