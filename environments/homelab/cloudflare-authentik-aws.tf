# Authentik on AWS: its tunnel, a test hostname, and the switch for auth.pdlab.dev (PET-932).
#
# environments/authentik runs a second Authentik on EC2. Its cloudflared connector dials out to
# the authentik-aws tunnel declared here, so the host needs no inbound port. auth.pdlab.dev is a
# CNAME to one tunnel or the other, chosen by var.authentik_side:
#   lab  -> the lab tunnel, then cloudflared on LXC 112, then LXC 119 (the rule in cloudflare-routes.tf)
#   aws  -> the authentik-aws tunnel, then the EC2 host
# Both tunnels keep an auth.pdlab.dev rule, so the switch is one record change. Every Access app
# and the Cloudflare OIDC login name auth.pdlab.dev, never an address, so none of them changes.
#
# auth-aws.pdlab.dev reaches the EC2 copy whatever the switch says. It is how you check that copy
# before and after a move. It is the same Authentik login as auth.pdlab.dev, and it adds no new
# way in: an account works there only where it already works on auth.pdlab.dev.
#
# The tunnel token never reaches state. scripts/seed-authentik-aws.sh reads it from the Cloudflare
# API and writes it to the host's SSM parameter, and Pedro runs it (PET-511).

variable "authentik_side" {
  description = "Where auth.pdlab.dev points: lab (LXC 119) or aws (environments/authentik). Move it to aws only after auth-aws.pdlab.dev answers with a restored copy."
  type        = string
  default     = "lab"

  validation {
    condition     = contains(["lab", "aws"], var.authentik_side)
    error_message = "authentik_side is lab or aws."
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "authentik_aws" {
  account_id = local.cloudflare_account_id
  name       = "authentik-aws"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "authentik_aws" {
  account_id = local.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.authentik_aws.id

  # The connector runs in the compose project beside the server, so it reaches it by service name.
  config = {
    ingress = [
      {
        hostname = "auth.pdlab.dev"
        service  = "http://server:9000"
      },
      {
        hostname = "auth-aws.pdlab.dev"
        service  = "http://server:9000"
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

locals {
  authentik_tunnel_cname = {
    lab = "${local.cloudflare_tunnel_id}.cfargotunnel.com"
    aws = "${cloudflare_zero_trust_tunnel_cloudflared.authentik_aws.id}.cfargotunnel.com"
  }
}

# The record the module created before PET-932. It keeps its id, so the move changes nothing.
moved {
  from = module.cloudflare_ingress.cloudflare_dns_record.route["auth.pdlab.dev"]
  to   = cloudflare_dns_record.authentik
}

resource "cloudflare_dns_record" "authentik" {
  zone_id = local.cloudflare_zone_id
  name    = "auth.pdlab.dev"
  type    = "CNAME"
  content = local.authentik_tunnel_cname[var.authentik_side]
  proxied = true
  ttl     = 1 # automatic, required when proxied
  comment = "Authentik. Side: ${var.authentik_side} (PET-932, var.authentik_side)."

  # The aws side must have its ingress rule before the name points at it.
  depends_on = [cloudflare_zero_trust_tunnel_cloudflared_config.authentik_aws]
}

resource "cloudflare_dns_record" "authentik_aws" {
  zone_id = local.cloudflare_zone_id
  name    = "auth-aws.pdlab.dev"
  type    = "CNAME"
  content = local.authentik_tunnel_cname["aws"]
  proxied = true
  ttl     = 1
  comment = "Authentik on AWS, whatever auth.pdlab.dev points at (PET-932)."

  depends_on = [cloudflare_zero_trust_tunnel_cloudflared_config.authentik_aws]
}

output "authentik_aws_tunnel_id" {
  description = "The authentik-aws tunnel. scripts/seed-authentik-aws.sh reads its token by this id. It is not a secret."
  value       = cloudflare_zero_trust_tunnel_cloudflared.authentik_aws.id
}

output "authentik_side" {
  description = "Where auth.pdlab.dev points: lab or aws."
  value       = var.authentik_side
}
