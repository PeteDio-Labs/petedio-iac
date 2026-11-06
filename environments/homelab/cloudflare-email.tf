# Mail for pdlab.dev. Cloudflare Email Routing receives mail for privacy@pdlab.dev and forwards it to
# Pedro's Gmail inbox. Proton's free plan cannot host a custom domain, so forwarding is the free path.
# Cloudflare creates the MX and SPF records when routing turns on. This zone holds no mail records otherwise.
#
# Cloudflare refuses a forwarding rule until the destination address is verified, so activation has two phases,
# each behind its own repository variable:
#   0. Add three permissions to the API token at kv/iac/cloudflare:
#        Zone > Email Routing Rules > Edit
#        Zone > Zone Settings > Edit        (the DNS resource turns routing on)
#        Account > Email Routing Addresses > Edit
#      Without them the first enabled apply fails.
#   1. Set the repository variable EMAIL_ROUTING_LIVE=true. The apply turns routing on and registers the
#      destination. Cloudflare then emails a verification link to it.
#   2. Click the link in the Gmail inbox (already verified in Cloudflare, so Cloudflare may skip the email).
#   3. Set EMAIL_ROUTING_FORWARD=true. The apply creates the forwarding rule.
variable "email_routing_live" {
  description = "Phase 1: turn on Cloudflare Email Routing for pdlab.dev and register the destination address. Keep false until the Cloudflare API token has the Email Routing and Zone Settings permissions."
  type        = bool
  default     = false
}

variable "email_routing_forward" {
  description = "Phase 2: create the forwarding rules. Set true only after email_routing_live is true and the destination address is verified."
  type        = bool
  default     = false

  validation {
    condition     = !var.email_routing_forward || var.email_routing_live
    error_message = "email_routing_forward needs email_routing_live = true: the rule depends on the destination address."
  }
}

locals {
  email_routing_destination = "pedelgadillo@gmail.com"
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
  for_each = var.email_routing_forward ? toset(local.email_routing_aliases) : toset([])

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
    value = [cloudflare_email_routing_address.destination[0].email]
  }]

  depends_on = [cloudflare_email_routing_dns.pdlab]
}
