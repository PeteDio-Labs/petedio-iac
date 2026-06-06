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
          no_tls_verify       = true                  # self-signed origin
          access              = true                  # gate via Cloudflare Access
          allowed_idps        = ["<authentik-idp-id>"] # from PET-38
          access_email_domain = "pdlab.dev"
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
    session_duration    = optional(string, "24h")
  }))
  default = {}
}
