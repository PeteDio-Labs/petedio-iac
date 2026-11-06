# portfolio-site (PET-774)

Static site hosting on AWS: a private S3 bucket, a CloudFront distribution with OAC, an ACM
certificate and a deploy identity for GitHub Actions (`deploy_auth`: an OIDC role, or a deploy-only IAM user). Nothing in `environments/` calls this module yet.
The first apply and the DNS change need Pedro's word.

## Cost: the module stays free

CloudFront has two free routes, and the module fits both.

| Route | Allowance | Over the allowance |
|---|---|---|
| Always-free tier, pay-as-you-go distribution (the module's default) | 1 TB transfer and 10 M requests a month, account-wide | Billed at standard rates, drawn from the credit |
| Free flat-rate plan (console subscription, one distribution) | 100 GB and 1 M requests a month | No charge; delivery may degrade after 2-3 months |

The AWS docs list what a Free-plan distribution must and must not use. The module meets each item:

- OAC, not OAI.
- The managed cache policy and a custom response headers policy (`headers.tf`: CSP, HSTS, nosniff, frame and referrer policies), no `ForwardedValues`. The docs found do not say whether the Free plan accepts a custom headers policy over the managed one. Check when subscribing; if it refuses, switch back to `Managed-SecurityHeadersPolicy` and lose the CSP.
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

## Deploy auth

`deploy_auth = "oidc"` (default) creates a GitHub OIDC role and no key. Use it on any account that allows
an IAM OIDC provider. The `847547470418` account does not: a service control policy on its organization
denies `iam:CreateOpenIDConnectProvider` and `iam:ListOpenIDConnectProviders` (PET-816), so
`environments/portfolio` sets `deploy_auth = "user"`.

`"user"` creates a deploy-only IAM user with the same policy. Terraform never creates its access key, so
no secret reaches state. `scripts/portfolio-deploy-key.sh` creates the key and stores it as secrets on the
repo's `production` environment, which only `main` may deploy to. Rotate with `--rotate`.

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
3. The ACM validation CNAME is declared in `environments/homelab/cloudflare-portfolio.tf`
   (unproxied). It applies on merge to `main`.
4. From `environments/portfolio`, apply with `-var attach_domain=true`. The apply waits for the certificate.
   Set `attach_domain` default to `true` in the same change so later plans keep the alias.
5. Set `portfolio_apex_live` to `true` in `cloudflare-portfolio.tf`. The apex CNAME points at
   `cloudfront_domain`; the apply on merge needs `ALLOW_DESTROY` while the tunnel CNAME for
   `pdlab.dev` is still in state. Rollback: set it back to `false` and restore a tunnel route.
