# PET-36 — bring the live Cloudflare tunnel routes under Terraform (zero-drift) and
# drop the dead ones (k8s services destroyed in PET-93: mc / searxng / argocd /
# portfolio / web-search).
#
# STEP 1 (this commit): ENUMERATE — read-only. No resources created or changed.
# The CI plan surfaces `live_tunnel_routes` + `all_dns_records` so we can see the
# real inventory and pick the keep-set before declaring/importing it via the
# modules/cloudflare-ingress "URL factory". `terraform validate` never reads data
# sources, so this stays green with no Vault; the runner's plan (token from Vault)
# resolves the actual values.

data "cloudflare_dns_records" "all" {
  zone_id = local.cloudflare_zone_id
}

# Hostnames whose proxied CNAME points at the cloudflared tunnel = the public
# routes. These are the candidates for the module's `routes` map (minus the dead).
output "live_tunnel_routes" {
  description = "PET-36: hostnames whose CNAME targets *.cfargotunnel.com (tunnel routes)."
  value = sort([
    for r in data.cloudflare_dns_records.all.result :
    r.name if try(strcontains(r.content, "cfargotunnel.com"), false)
  ])
}

# Full DNS inventory (every record) for the migration writeup.
output "all_dns_records" {
  description = "PET-36: every DNS record as 'name TYPE -> content' for the inventory."
  value = sort([
    for r in data.cloudflare_dns_records.all.result :
    "${r.name} ${r.type} -> ${r.content}"
  ])
}