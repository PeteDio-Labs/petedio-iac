# Mail for pdlab.dev. Cloudflare Email Routing receives mail for privacy@pdlab.dev and forwards it to
# Pedro's Proton inbox. Proton's free plan cannot host a custom domain, so forwarding is the free path.
# Cloudflare creates the MX and SPF records when routing turns on. This zone holds no mail records otherwise.
#
# Two steps stay with Pedro, because Terraform cannot do them:
#   1. The API token at kv/iac/cloudflare needs Email Routing permissions: Zone > Email Routing Rules > Edit
#      and Account > Email Routing Addresses > Edit. Without them the apply fails.
#   2. Cloudflare emails a verification link to the destination address. Click it once. A rule that points
#      at an unverified address forwards nothing.
# Keep email_routing_live false until step 1 is done, then set it true.
variable "email_routing_live" {
  description = "Turn on Cloudflare Email Routing for pdlab.dev and forward privacy@pdlab.dev to the destination below. Keep false until the Cloudflare API token has Email Routing permissions."
  type        = bool
  default     = false
}

locals {
  email_routing_destination = "petedillo@proton.me"
  email_routing_aliases     = ["privacy@pdlab.dev"]
}

resource "cloudflare_email_routing_dns" "pdlab" {
  count = var.email_routing_live ? 1 : 0

  zone_id = local.cloudflare_zone_id
  name    = "pdlab.dev"
}

resource "cloudflare_email_routing_address" "destination" {
  count = var.email_routing_live ? 1 : 0

  account_id = local.cloudflare_account_id
  email      = local.email_routing_destination
}

resource "cloudflare_email_routing_rule" "alias" {
  for_each = var.email_routing_live ? toset(local.email_routing_aliases) : toset([])

  zone_id = local.cloudflare_zone_id
  name    = "Forward ${each.value}"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = each.value
  }]

  actions = [{
    type  = "forward"
    value = [local.email_routing_destination]
  }]

  depends_on = [cloudflare_email_routing_dns.pdlab]
}
