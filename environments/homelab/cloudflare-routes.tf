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

    # Co-latro — the game, prealpha (PET-58). nginx on VM-230 (poker-api) serves the frontend
    # dist/ and reverse-proxies /api to the backend on :3020 (same origin, relative API calls).
    # PET-206: edge CF Access DROPPED. The app now has real auth — invite-gated signup (PET-59) +
    # argon2id password login — so the app IS the gate; the CF Access email-allowlist only blocked
    # testers (no OTP unless allow-listed). Public URL, useless without an admin-issued invite +
    # account. (Removing access=true destroys this hostname's Access application/policy on apply.)
    "co-latro.pdlab.dev" = {
      service = "http://192.168.50.230:80"
    }

    # Co-latro Admin portal (PET-87). Served from the poker-api VM-230 as a NAME-BASED nginx
    # vhost (server_name admin.pdlab.dev), alongside the default co-latro site: static admin UI
    # + /function/* reverse-proxied to the faasd gateway on LXC 241 (230 is the only origin the
    # gateway firewall allows — PET-204/F1). The tunnel forwards Host: admin.pdlab.dev to the
    # origin (module sets origin_request.http_host_header), so the name-based vhost matches.
    #
    # Gated by Cloudflare Access, login via the ADMIN's Authentik user (NOT One-Time PIN):
    # allowed_idps points at the Authentik OIDC IdP (cloudflare-oidc.tf), so the module sets
    # auto_redirect_to_identity = true and the browser goes straight to the auth.pdlab.dev
    # login page. access_emails still does the AUTHORIZATION (only this email passes) as
    # defense-in-depth after Authentik authenticates — so the Authentik user MUST present this
    # email address. Prereq: the manual Authentik app + kv/iac/authentik seed (cloudflare-oidc.tf).
    "admin.pdlab.dev" = {
      service       = "http://192.168.50.230:80"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]
    }

    # Palworld control panel (PET-266). Origin is the panel's Bun service on the game LXC 234
    # (:8080 — native co-located deploy, PR #152; serves the SPA + /api + SSE). Gated by
    # Cloudflare Access with Authentik OIDC login, same pattern as admin.pdlab.dev; the email
    # allow-list AUTHORIZES after Authentik authenticates. The panel can power the game server
    # off/on, so keep this list tight: sonia + pedro.
    "palworld.pdlab.dev" = {
      service       = "http://192.168.50.234:8080"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["soniasdelgadillo@gmail.com", "pedelgadillo@gmail.com"]
    }

    # Resume builder (Resume Builder milestone, P1). Origin is the SvelteKit app on
    # resume-242 (:8080 — same co-located-deploy pattern as the palworld panel; ex
    # agent-loop-242, PET-265 P0 teardown). Gated by Cloudflare Access with Authentik OIDC
    # login; the email allow-list AUTHORIZES after Authentik authenticates. Sonia is the
    # only provisioned APP user (enforced again at the app layer, planning doc §4) — pedro
    # stays in the CF Access policy for ops/deploy testing only.
    "cv.pdlab.dev" = {
      service       = "http://192.168.50.242:8080"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["soniasdelgadillo@gmail.com", "pedelgadillo@gmail.com"]
    }
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