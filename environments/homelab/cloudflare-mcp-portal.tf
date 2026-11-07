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
# Open questions the first plan or apply answers, not this file:
#   - Whether the Free plan accepts the create call.
#   - Whether the portal hostname needs a DNS record beside this resource.
#   - Whether the portal reaches an upstream that is itself behind Access managed OAuth
#     with auth_type "oauth", or needs a different auth_type.

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "plane" {
  account_id  = local.cloudflare_account_id
  id          = "plane"
  name        = "Plane"
  description = "PeteDio Plane work items (PET-839)."
  hostname    = "https://mcp-plane.pdlab.dev/mcp"
  auth_type   = "oauth"

  # Set explicitly. The API returns false and the provider reads it back as null when the
  # attribute is unset, so the plan shows `false -> null` and the PUT sends null, which the
  # API rejects with 400 "Expected boolean, received null" (PET-839).
  is_shared_oauth_callback_enabled = false
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "lab" {
  account_id  = local.cloudflare_account_id
  id          = "lab"
  name        = "Lab"
  description = "Read-only homelab state (PET-839)."
  hostname    = "https://mcp-lab.pdlab.dev/mcp/lab"
  auth_type   = "oauth"

  # Set explicitly. The API returns false and the provider reads it back as null when the
  # attribute is unset, so the plan shows `false -> null` and the PUT sends null, which the
  # API rejects with 400 "Expected boolean, received null" (PET-839).
  is_shared_oauth_callback_enabled = false
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
