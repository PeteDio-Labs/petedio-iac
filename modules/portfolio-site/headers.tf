# Security headers for the portfolio (PET-820). The site ships no inline script and loads only
# its own fonts and the Cloudflare Web Analytics beacon, so the policy can stay tight: scripts
# from 'self' and the beacon host. Style attributes are inline in the pages, so style-src needs
# 'unsafe-inline'. petedio-labs/pdlabs-portfolio has a test that fails when a page gains an
# inline script, which is what keeps this policy valid.

locals {
  csp = join("; ", [
    "default-src 'self'",
    "script-src 'self' https://static.cloudflareinsights.com",
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self'",
    "img-src 'self' data:",
    "connect-src 'self' https://cloudflareinsights.com",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ])
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${var.name}-security"
  comment = "CSP, HSTS and the standard hardening headers for the portfolio"

  security_headers_config {
    content_security_policy {
      content_security_policy = local.csp
      override                = true
    }
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), interest-cohort=()"
      override = true
    }
  }
}

# The read-only JSON API under /api/* (case studies as data). It carries the same hardening headers
# as the site, plus a public CORS policy, so a browser on another origin can fetch it. The policy
# lets GET and HEAD from any origin, with no credentials, because the content is the public site's own.
# A plain GET needs no preflight, and S3 does not answer OPTIONS, so the behavior allows GET and HEAD only. The site's pages keep the policy above, which sends no CORS headers.
resource "aws_cloudfront_response_headers_policy" "api" {
  name    = "${var.name}-api"
  comment = "Security headers plus public read-only CORS for /api/*"

  cors_config {
    access_control_allow_credentials = false
    access_control_max_age_sec       = 86400
    origin_override                  = true

    # The provider requires this block. A plain GET sends no custom request headers.
    access_control_allow_headers {
      items = ["*"]
    }
    access_control_allow_methods {
      items = ["GET", "HEAD"]
    }
    access_control_allow_origins {
      items = ["*"]
    }
  }

  security_headers_config {
    content_security_policy {
      content_security_policy = local.csp
      override                = true
    }
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), interest-cohort=()"
      override = true
    }
  }
}
