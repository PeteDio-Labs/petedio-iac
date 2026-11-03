# portfolio-site (PET-774)

Static site hosting on AWS: a private S3 bucket, a CloudFront distribution with OAC, an ACM
certificate and a GitHub OIDC deploy role. Nothing in `environments/` calls this module yet.
The first apply and the DNS change need Pedro's word.

## Cost: the module stays free

CloudFront has two free routes, and the module fits both.

| Route | Allowance | Over the allowance |
|---|---|---|
| Always-free tier, pay-as-you-go distribution (the module's default) | 1 TB transfer and 10 M requests a month, account-wide | Billed at standard rates, drawn from the credit |
| Free flat-rate plan (console subscription, one distribution) | 100 GB and 1 M requests a month | No charge; delivery may degrade after 2-3 months |

The AWS docs list what a Free-plan distribution must and must not use. The module meets each item:

- OAC, not OAI.
- Managed cache and response-header policies, no `ForwardedValues`.
- At most 5 cache behaviors (this has 1) and one CloudFront Function.
- A WAF web ACL is **required** on a plan. The module attaches none, so subscribing is a
  console step that creates one.

Two points stay unverified: an account on the AWS Free account plan may count as "using AWS Free
Tier", which the docs list as ineligible for flat-rate plans, and no documentation found says
whether the `aws` provider can subscribe a distribution to a plan. Check both in the console
before relying on the plan. The always-free route needs neither.

Other resources: ACM public certificates cost nothing, S3 storage for a static site is cents,
and 1,000 invalidation paths a month are free. The deploy workflow sends one (`/*`) per run.
DNS stays in Cloudflare, so Route 53 is not used.

Source: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>.

## Usage

```hcl
provider "aws" {
  region = "us-east-2"
}

provider "aws" {
  alias  = "us_east_1" # CloudFront reads ACM certificates only from here
  region = "us-east-1"
}

module "portfolio" {
  source = "../../modules/portfolio-site"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
}
```

The account is `847547470418`. Put the module in its own root with its own state, like
`environments/offsite-watchdog`, so an AWS fault cannot touch the homelab plan.

## Rollout order

1. Apply with `attach_domain = false`. Set `AWS_ROLE_ARN`, `BUCKET` and `DISTRIBUTION_ID` as
   variables on the `portfolio` repo from the outputs. They are identifiers, not secrets.
2. Run the portfolio deploy workflow. Open `cloudfront_domain` and check the pages.
3. Create the `acm_validation_records` in Cloudflare with the proxy off.
4. Apply with `attach_domain = true`. The apply waits for the certificate.
5. Point the apex at `cloudfront_domain` with a proxied-off CNAME (Cloudflare flattens it).
   This cutover moves `pdlab.dev` traffic. Check the existing apex records first.
