# Distribution shape is chosen so the CloudFront Free flat-rate plan stays available: OAC (not
# OAI), the AWS managed cache policy and our own response headers policy, headers.tf (no ForwardedValues), two behaviors (the site and /api/*), one function,
# no real-time logs. The module attaches no WAF and no plan: see README.md for why.

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# S3 through OAC has no directory index, so /case-studies/ must become /case-studies/index.html.
# The build writes pages as <name>.html (work.html, work/ssh-ca.html), so an extensionless path
# such as /work maps to /work.html. A path with an extension passes through unchanged.
resource "aws_cloudfront_function" "index_rewrite" {
  name    = "${var.name}-index-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
      } else if (!uri.split('/').pop().includes('.')) {
        request.uri = uri + '.html';
      }
      return request;
    }
  EOT
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name} static site"
  default_root_object = "index.html"
  price_class         = var.price_class
  http_version        = "http2and3"
  aliases             = var.attach_domain ? [var.domain_name] : []
  tags                = var.tags

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  # The JSON API. Same origin, cache policy and rewrite function as the site; only the response
  # headers policy differs, because it adds CORS. Nothing else on the site gets CORS headers.
  ordered_cache_behavior {
    path_pattern               = "/api/*"
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.api.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  # A private bucket answers 403 for a missing key.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.attach_domain ? null : true
    acm_certificate_arn            = var.attach_domain ? aws_acm_certificate_validation.site[0].certificate_arn : null
    ssl_support_method             = var.attach_domain ? "sni-only" : null
    minimum_protocol_version       = var.attach_domain ? "TLSv1.2_2021" : null
  }
}
