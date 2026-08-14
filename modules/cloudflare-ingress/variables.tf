# cloudflare-ingress — the "URL factory". Turn a route map into Cloudflare tunnel
# ingress + proxied DNS (+ optional Access gating). Add one map entry -> plan -> apply. (PET-35)

variable "account_id" {
  type        = string
  description = "Cloudflare account ID (from the F1 data sources / Vault kv/iac/cloudflare)."
}

variable "zone_id" {
  type        = string
  description = "pdlab.dev zone ID."
}

variable "tunnel_id" {
  type        = string
  description = "UUID of the existing cloudflared tunnel."
}

variable "tunnel_cname" {
  type        = string
  description = "The tunnel's CNAME target — <tunnel-id>.cfargotunnel.com (data.cloudflare_zero_trust_tunnel_cloudflared.main.cname / id)."
}

variable "routes" {
  description = <<-EOT
    Map of public hostname -> route config. Example:
      {
        "vault.pdlab.dev" = {
          service             = "https://192.168.50.223:8200"
          no_tls_verify       = true                   # self-signed origin
          access              = true                   # gate via Cloudflare Access
          allowed_idps        = ["<authentik-idp-id>"] # from PET-38 (OIDC); empty -> OTP login
          access_email_domain = "pdlab.dev"            # gate by email DOMAIN, or...
          access_emails       = ["you@example.com"]    # ...gate to specific email(s) (takes precedence)

          # Managed OAuth — turns this Access app into an OAuth 2.1 authorization
          # server for NON-BROWSER clients (MCP, CLIs, agents). With it on, Access
          # answers 401 + WWW-Authenticate instead of redirecting, and serves
          # discovery metadata. Only set this for an origin that does NOT run its
          # own OAuth: Cloudflare documents Managed OAuth as incompatible with
          # apps that emit their own WWW-Authenticate.
          managed_oauth = {
            allowed_redirect_uris = ["https://claude.ai/api/mcp/auth_callback"]
            access_token_lifetime = "15m"
            session_duration      = "168h"
          }
        }
      }
  EOT
  type = map(object({
    service             = string
    path                = optional(string)
    no_tls_verify       = optional(bool, false)
    access              = optional(bool, false)
    allowed_idps        = optional(list(string), [])
    access_email_domain = optional(string)
    access_emails       = optional(list(string), [])
    session_duration    = optional(string, "24h")

    # Omit entirely for ordinary browser-gated apps (the default): a null here
    # leaves oauth_configuration unset, which is the pre-Managed-OAuth behaviour.
    managed_oauth = optional(object({
      enabled               = optional(bool, true)
      allowed_redirect_uris = optional(list(string), [])
      allow_any_on_loopback = optional(bool, false)
      access_token_lifetime = optional(string, "15m")
      session_duration      = optional(string, "168h")
    }))
  }))
  default = {}
}
