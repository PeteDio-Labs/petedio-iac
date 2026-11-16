# Route 53 holds a delegated subdomain (var.zone_name). Cloudflare keeps pdlab.dev and carries
# one NS record per name server printed in the `name_servers` output.
#
# Two apply phases. Phase 1 (attach_domain = false) creates the zone and the AWS stack. You then
# add the delegation in Cloudflare (environments/homelab). Phase 2 (attach_domain = true) issues
# the certificate through the zone, aliases the distribution and creates the failover records.
resource "aws_route53_zone" "failover" {
  name    = var.zone_name
  comment = "Failover subdomain delegated from the Cloudflare zone"
}

resource "aws_acm_certificate" "site" {
  count    = var.attach_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = var.attach_domain ? {
    for o in aws_acm_certificate.site[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = aws_route53_zone.failover.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count    = var.attach_domain ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# Health check on the AWS side. GET /api/health is public and reads one DynamoDB item. The check
# goes to the distribution's own name, so it tests the path a viewer takes.
resource "aws_route53_health_check" "cloud" {
  count = var.attach_domain ? 1 : 0

  fqdn              = aws_cloudfront_distribution.site.domain_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/api/health"
  request_interval  = 30
  failure_threshold = 3
  measure_latency   = false

  tags = { Name = "${var.name}-cloud" }
}

resource "aws_route53_record" "primary" {
  count = var.attach_domain ? 1 : 0

  zone_id         = aws_route53_zone.failover.zone_id
  name            = var.hostname
  type            = "A"
  set_identifier  = "cloud"
  health_check_id = aws_route53_health_check.cloud[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false # the explicit health check above decides
  }
}

resource "aws_route53_record" "primary_aaaa" {
  count = var.attach_domain ? 1 : 0

  zone_id         = aws_route53_zone.failover.zone_id
  name            = var.hostname
  type            = "AAAA"
  set_identifier  = "cloud"
  health_check_id = aws_route53_health_check.cloud[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

# The SECONDARY record is the on-prem fallback. It stays off until README.md's open question is
# answered, because a CNAME to a Cloudflare-proxied name does not terminate TLS for this hostname.
resource "aws_route53_record" "secondary" {
  count = var.attach_domain && var.lab_fallback_target != null ? 1 : 0

  zone_id        = aws_route53_zone.failover.zone_id
  name           = var.hostname
  type           = "CNAME"
  set_identifier = "lab"
  ttl            = 60
  records        = [var.lab_fallback_target]

  failover_routing_policy {
    type = "SECONDARY"
  }
}
