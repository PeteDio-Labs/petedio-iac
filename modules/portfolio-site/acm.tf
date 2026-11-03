# Free public certificate. Validation is by DNS record in Cloudflare, created outside this
# module (see output acm_validation_records).
resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Blocks until the record resolves, so it exists only once attach_domain is true.
resource "aws_acm_certificate_validation" "site" {
  count           = var.attach_domain ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.site.arn
}
