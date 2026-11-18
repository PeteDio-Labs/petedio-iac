# PET-942 - delegates failover.pdlab.dev from Cloudflare to the Route 53 zone that
# environments/dashboard creates. Route 53 then answers the failover records for this subdomain.
# The name servers are outputs of environments/dashboard (identifiers, not secrets). If the Route 53
# zone is recreated, its name servers change and this list must change with it.

locals {
  failover_name_servers = [
    "ns-1190.awsdns-20.org",
    "ns-137.awsdns-17.com",
    "ns-1963.awsdns-53.co.uk",
    "ns-681.awsdns-21.net",
  ]
}

resource "cloudflare_dns_record" "failover_ns" {
  for_each = toset(local.failover_name_servers)

  zone_id = local.cloudflare_zone_id
  name    = "failover.pdlab.dev"
  type    = "NS"
  content = each.value
  ttl     = 3600
  comment = "Delegates failover.pdlab.dev to Route 53 (PET-942)."
}
