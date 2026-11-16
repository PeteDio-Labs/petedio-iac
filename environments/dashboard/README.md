# Lab dashboard, AWS side

Terraform for the AWS primary of the lab dashboard. The SPA, API and sign-in live here. pete-bot on 237 stays the warm on-prem fallback.

The app code is in `petedio-labs/pete-bot` under `dashboard/`. This root owns existence and permissions. It never owns code: a deploy user ships the SPA and the Lambda bundle.

## What it creates

| Part | Resource | Notes |
|---|---|---|
| SPA | S3 bucket behind CloudFront (OAC) | Private bucket. A deep link returns `index.html`. |
| Data | DynamoDB table `dash` (`pk`, `sk`, TTL `expires`) | On demand. Items are snapshots the lab pushes again. |
| API | HTTP API + one Lambda (`nodejs22.x`, arm64) | Stub handler until the deploy ships `handler.mjs`. |
| Sign-in | Cognito user pool, one admin-created user, optional TOTP | Does not use Authentik, the first failover service. |
| DNS | Route 53 zone for `failover.pdlab.dev` | Cloudflare keeps `pdlab.dev` and delegates this subdomain. |
| Failover | Health check and a PRIMARY alias for `dash.failover.pdlab.dev` | The SECONDARY record waits on the open question below. |
| Principals | `petedio-dash-ingest`, `petedio-dash-deploy` IAM users | No access keys in Terraform. A script that Pedro runs makes each key. |

Routes (from the dashboard thread's contract): `GET /api/health` (public), `GET /api/dashboard` and `POST /api/switch` (Cognito JWT), `POST /api/ingest/status` and `POST /api/ingest/section` (IAM, SigV4). Callers sign ingest requests against the `api_endpoint` output directly, not through CloudFront, because SigV4 signs the `Host` header.

## Cost estimate

Nothing here runs a server. Estimates, to confirm in Billing after the first month:

- Route 53: $0.50 for the zone, about $0.75 for one HTTPS health check to a non-AWS-endpoint name.
- CloudFront, Lambda, API Gateway, DynamoDB, Cognito: inside the free tiers at one user.
- CloudWatch Logs: 14-day retention keeps this under $0.50.

Expect about $2 a month. The credit budget in `environments/offsite-watchdog/budgets.tf` covers it. The tags `project=petedio-dashboard` and `expires=2027-04-20` mark every resource.

## Apply order (host step, after Pedro says go)

Nothing runs from CI. Apply from the Mac or 247 with the account's admin profile.

1. **Phase 1.** `terraform apply -var aws_profile=<profile>` with `attach_domain = false`. This creates the whole stack on the `cloudfront.net` URL and the Route 53 zone.
2. **Delegation.** Add one NS record per `name_servers` output for `failover.pdlab.dev` to `environments/homelab` (Cloudflare), DNS only. Apply that through the normal merge.
3. **Phase 2.** Set `attach_domain = true` and apply. The apply waits for ACM to validate through the delegation, then aliases the distribution and creates the health check.
4. **Keys.** Pedro runs the key scripts for `petedio-dash-ingest` and `petedio-dash-deploy` (a later PR). No session places a credential.
5. **Code.** The deploy workflow syncs `dashboard/dist/` (without `fixtures/`) to the bucket, invalidates `/*` and runs `aws lambda update-function-code`.

## On-prem fallback: where TLS ends

A failover pair needs a SECONDARY target that can answer for `dash.failover.pdlab.dev` over HTTPS. The lab has no inbound port, and its only public path is a Cloudflare tunnel. Cloudflare serves a hostname only when the name sits in its own zone, so a CNAME from the Route 53 name to `reports.pdlab.dev` fails the TLS handshake. The SECONDARY record therefore stays off (`lab_fallback_target = null`).

Options, with a recommendation:

1. **CloudFront origin group (recommended).** The hostname always terminates at CloudFront with the ACM certificate. A second distribution origin points at `reports.pdlab.dev` through a Cloudflare Access service token, and CloudFront fails over per request on 5xx or timeout. This works when the lab is down and needs no Route 53 flip for the dashboard. Route 53 still carries the generic per-service pair (Authentik next) and the health checks.
2. **Cloudflare Load Balancing.** Pools for AWS and the tunnel, health-checked, with Access in front. It costs about $5 a month (estimate) and keeps the failover at Cloudflare, so a Cloudflare outage removes it.
3. **Move the apex to Route 53.** Closes the Cloudflare-DNS gap but moves all DNS. Pedro's call.

This root builds the parts all three share. Option 1 adds a second origin and an origin group to `web.tf` and a Cloudflare Access service token.

## Open items

- `GET /api/health` is a route here and a handler requirement for the dashboard thread: it must read one DynamoDB item and answer `{"ok":true}` or fail.
- The Cloudflare NS delegation lands in `environments/homelab`, in its own PR, after phase 1.
- A plan-only CI job for this root (like `portfolio-plan.yml`) needs a read-only AWS key that Pedro seeds.
