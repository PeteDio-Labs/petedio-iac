# PET-816 / PET-777 - DNS for the portfolio at the root of pdlab.dev.
#
# The site lives in AWS (S3 + CloudFront, account 847547470418, state in environments/portfolio).
# The zone lives in Cloudflare, so the two records the site needs are declared here.
# Rollout order is in modules/portfolio-site/README.md.

locals {
  # Outputs of environments/portfolio (identifiers, not secrets).
  portfolio_cloudfront_domain = "d1irfof2v9tr2n.cloudfront.net"
  portfolio_acm_validation = {
    name  = "_b57bd787bfb4d983b447070abde9e96b.pdlab.dev"
    value = "_cb658be10d79ffc29ac31cfaaf47f260.wzccmgtwzk.acm-validations.aws"
  }
}

variable "portfolio_apex_live" {
  description = "Point the pdlab.dev apex at CloudFront. Keep false unless environments/portfolio has attach_domain = true, because CloudFront answers 403 for a host it has no alias for. It is true since the alias went live (PET-816)."
  type        = bool
  default     = true
}

# ACM proves ownership of pdlab.dev by this CNAME. It must stay unproxied, and it must stay after
# issuance: ACM re-reads it to renew the certificate.
resource "cloudflare_dns_record" "portfolio_acm_validation" {
  zone_id = local.cloudflare_zone_id
  name    = local.portfolio_acm_validation.name
  type    = "CNAME"
  content = local.portfolio_acm_validation.value
  ttl     = 300
  proxied = false
  comment = "ACM DNS validation for the portfolio certificate (PET-816)."
}

# The apex. Cloudflare flattens an apex CNAME. It stays unproxied so CloudFront terminates TLS with
# the ACM certificate and Cloudflare adds no second layer. The tunnel CNAME for this name leaves
# module.cloudflare_ingress with the path routes (PET-827). Cloudflare rejects two records on one
# name, so the destroy must land first; depends_on orders it.
resource "cloudflare_dns_record" "portfolio_apex" {
  count = var.portfolio_apex_live ? 1 : 0

  zone_id = local.cloudflare_zone_id
  name    = "pdlab.dev"
  type    = "CNAME"
  content = local.portfolio_cloudfront_domain
  ttl     = 300
  proxied = false
  comment = "Portfolio on CloudFront (PET-816). Roll back by removing this block and restoring the tunnel route."

  depends_on = [module.cloudflare_ingress]
}
