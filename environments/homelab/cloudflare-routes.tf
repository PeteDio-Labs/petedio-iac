# PET-36 — Cloudflare tunnel routes under Terraform; dead routes dropped.
#
# The cloudflared tunnel is token-managed (routes live in Cloudflare, not on the
# box). This adopts the tunnel config + the live keep-set CNAMEs into the
# cloudflare-ingress module (PET-35) and rewrites the ingress to ONLY the keep
# routes, dropping the 11 dead ones whose backends were destroyed in PET-93:
#   k8s:        argocd, grafana, mc, mc-dev, mc-mcp, petedillo.com, www.petedillo.com
#   LXCs gone:  files (102), *.sandbox (120), job-hunt (118)
#   legacy:     media (-> old MinIO 115)
#
# Keep-set `service` values + record IDs were read from the live tunnel ingress
# (PR #31 plan, steps 1/1b). TF reads the CF token + account/zone/tunnel IDs from
# Vault (kv/iac/cloudflare) — no manual secret handling. After apply the 11 dead
# routes return 404 (their ingress rules removed); deleting the now-orphaned dead
# CNAMEs is optional follow-up hygiene.

module "cloudflare_ingress" {
  source = "../../modules/cloudflare-ingress"

  account_id   = local.cloudflare_account_id
  zone_id      = local.cloudflare_zone_id
  tunnel_id    = local.cloudflare_tunnel_id
  tunnel_cname = "${local.cloudflare_tunnel_id}.cfargotunnel.com"

  # KEEP — live services. Everything else is dropped by the ingress rewrite.
  routes = {
    "auth.pdlab.dev"     = { service = "http://192.168.50.119:9000" } # Authentik
    "docker.pdlab.dev"   = { service = "http://192.168.50.111:8082" } # Nexus (docker)
    "registry.pdlab.dev" = { service = "http://192.168.50.111:8081" } # Nexus (registry)
    "seer.pdlab.dev"     = { service = "http://192.168.50.33:5055" }  # Overseerr

    # PET-37 (F4) — Vault UI public URL. HTTPS origin behind a self-signed CA, so
    # no_tls_verify. access stays false here BY DESIGN: F5/PET-38 flips on the
    # Cloudflare Access gate (Authentik IdP). ⚠ Until F5 lands, applying this leaves
    # Vault's UI reachable from the internet (login-gated only) — see PR caveat.
    "vault.pdlab.dev" = { service = "https://192.168.50.223:8200", no_tls_verify = true }
  }
}

# Adopt the existing tunnel configuration so the apply is a clean diff that
# removes the 11 dead ingress rules (not a blind overwrite).
import {
  to = module.cloudflare_ingress.cloudflare_zero_trust_tunnel_cloudflared_config.this
  id = "${local.cloudflare_account_id}/${local.cloudflare_tunnel_id}"
}

# Adopt the existing keep CNAMEs (record IDs from the live pdlab.dev zone).
import {
  to = module.cloudflare_ingress.cloudflare_dns_record.route["auth.pdlab.dev"]
  id = "${local.cloudflare_zone_id}/61c79a4269f9bd3113d1f306219009e9"
}
import {
  to = module.cloudflare_ingress.cloudflare_dns_record.route["docker.pdlab.dev"]
  id = "${local.cloudflare_zone_id}/cc952b328455a928811c5ad980f11599"
}
import {
  to = module.cloudflare_ingress.cloudflare_dns_record.route["registry.pdlab.dev"]
  id = "${local.cloudflare_zone_id}/0bc0916310c01640872d57482f14c637"
}
import {
  to = module.cloudflare_ingress.cloudflare_dns_record.route["seer.pdlab.dev"]
  id = "${local.cloudflare_zone_id}/553f672178651906b01c66cdca2c9de7"
}