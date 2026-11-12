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
    "auth.pdlab.dev" = { service = "http://192.168.50.119:9000" } # Authentik
    "seer.pdlab.dev" = { service = "http://192.168.50.33:5055" }  # Overseerr

    # docker.pdlab.dev / registry.pdlab.dev REMOVED from the tunnel — Nexus is
    # gone, replaced by zot on the same LXC. The registry is deliberately no
    # longer reachable from the internet: its only consumers (runner-232/233,
    # faasd on 241) are all on the LAN, so routing them out to Cloudflare and
    # back in was pure latency and pure attack surface. docker.pdlab.dev had
    # a plain A record straight to the box until PET-778 removed it with the dead host.
    # registry.pdlab.dev is retired outright: it fronted Nexus's web UI, which zot
    # replaces with its own, LAN-only.

    # Co-latro and its admin portal are GONE (PET-366). Both were served from VM-230,
    # which is destroyed; leaving either hostname here would point the tunnel at nothing.
    # Removing admin.pdlab.dev also destroys its Access application and policy, and with
    # it the last consumer of the Authentik IdP for a browser-gated route — the IdP stays
    # (cloudflare-oidc.tf) because it is the login path for anything gated later.

    # palworld.pdlab.dev is retired (PET-779). Its Access app, policy and CNAME went with
    # module.cloudflare_ingress_palworld.

    # The Plane and lab MCP servers on their own hostnames (PET-824), so the apex can serve the
    # portfolio from CloudFront (PET-816). The old pdlab.dev/mcp/<name> path routes are gone
    # (PET-827). Managed OAuth gates an MCP client that speaks OAuth and never renders a page,
    # unlike the browser-gated routes above. access_emails is the WHOLE authorization boundary:
    # the Plane shim holds a service PAT and lab-agent sees Proxmox and Vault metadata, so keep
    # each list to one person.
    #
    # Both origins are LAN addresses because cloudflared runs on LXC 112, a different host.
    # The Plane shim checks no Access JWT, so the origin firewall on 235
    # (plane-mcp-firewall.service) admits only 112. lab-agent admits only 112 and verifies the
    # JWT's audience tag and email, and the lab-mcp allowlist on 237 drops every other source.
    #
    # Plane: the :8790 site of the Caddy shim already maps /mcp to the server's mount, so the
    # connector URL is https://mcp-plane.pdlab.dev/mcp.
    "mcp-plane.pdlab.dev" = {
      service       = "http://192.168.50.235:8790"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]

      managed_oauth = {
        # The Zero Trust dashboard's admin sign-in ("Authenticate server") redirects here (PET-839).
        allowed_redirect_uris = [
          "https://claude.ai/api/mcp/auth_callback",
          "https://dash.cloudflare.com/${local.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/plane",
          # Cloudflare's shared outbound callback, sent when a portal user signs in to the upstream (PET-839).
          "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
        ]
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # Lab: lab-agent serves only /mcp/lab (pete-bot src/lab/mcp.ts MCP_PATH), so the connector
    # URL is https://mcp-lab.pdlab.dev/mcp/lab. This Access app has its own audience tag, so
    # lab-agent needs lab_agent_access_aud set to the lab_mcp_subdomain_access_aud output
    # before this route answers.
    "mcp-lab.pdlab.dev" = {
      service       = "http://192.168.50.237:3017"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]

      managed_oauth = {
        # The Zero Trust dashboard's admin sign-in ("Authenticate server") redirects here (PET-839).
        allowed_redirect_uris = [
          "https://claude.ai/api/mcp/auth_callback",
          "https://dash.cloudflare.com/${local.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/lab",
          # Cloudflare's shared outbound callback, sent when a portal user signs in to the upstream (PET-839).
          "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
        ]
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # Media: mtrace on 237 serves /mcp/media on its own MCP port, 8238 (media-control src/mcp.ts), so the
    # connector URL is https://mcp-media.pdlab.dev/mcp/media. mtrace verifies this Access app's
    # audience tag and email, and its nftables allowlist on 237 admits only 112 on 8238, and never reaches the API port 8237. The door
    # lists the read tools only. mtrace stays off the door until mtrace_mcp_access_aud is set to the
    # media_mcp_subdomain_access_aud output.
    "mcp-media.pdlab.dev" = {
      service       = "http://192.168.50.237:8238"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]
      # The Muse agents (PET-904). Each sends its service token in Cf-Access-Token, and mtrace maps
      # the JWT's client id to the name through mtrace_mcp_access_agents.
      agents = ["bobbert", "batsy"]

      managed_oauth = {
        allowed_redirect_uris = [
          "https://claude.ai/api/mcp/auth_callback",
          "https://dash.cloudflare.com/${local.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/media",
          "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
        ]
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # The weekly PR dashboard (PET-868), served by pete-bot on 237. A browser-gated route, so
    # Access shows its login page and pete-bot verifies the Cf-Access-Jwt-Assertion JWT (its
    # audience tag and email) as lab-agent does. Port 3018 is separate from the bot's 3015, so the
    # alert intake is never reachable through the tunnel. The origin is a LAN address because
    # cloudflared runs on LXC 112; weekly-dash-allowlist on 237 admits only 112.
    # access_emails is the whole boundary: keep it to Pedro alone.
    "reports.pdlab.dev" = {
      service       = "http://192.168.50.237:3018"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]
    }

    # Tom's Plane MCP (PET-610), a copy of mcp-plane.pdlab.dev with a different origin port and email.
    # The origin is the :8791 site of the same Caddy shim, which swaps in Tom's PAT from
    # kv/services/plane-tom, so every call acts as Tom and Plane enforces his roles. The same
    # rule applies as above: access_emails is the whole boundary, so keep it to Tom alone, and
    # keep mcp-plane.pdlab.dev to Pedro alone.
    "mcp-tom.pdlab.dev" = {
      service       = "http://192.168.50.235:8791"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["tsilveri406@gmail.com"]

      managed_oauth = {
        allowed_redirect_uris = ["https://claude.ai/api/mcp/auth_callback"]
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # Sonia's Plane MCP (PET-650), the same shape as mcp-tom.pdlab.dev. The origin is the :8792
    # site of the Caddy shim, which swaps in Sonia's PAT from kv/services/plane-sonia, so every
    # call acts as Sonia. She is a workspace Admin on Pedro's word, so this route can do what an
    # Admin can. access_emails is the whole boundary: keep it to Sonia alone.
    "mcp-sonia.pdlab.dev" = {
      service       = "http://192.168.50.235:8792"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["soniasdelgadillo@gmail.com"]

      managed_oauth = {
        allowed_redirect_uris = ["https://claude.ai/api/mcp/auth_callback"]
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # The Plane board (PET-610), so Tom can work in it from outside the lab. The origin is
    # Plane's own proxy on plane-235, a LAN address because cloudflared runs on LXC 112.
    # Access is the gate, with the Authentik IdP, and the emails are the whole allow-list:
    # Pedro, Tom and Sonia (PET-650). Only the app is routed. Attachments live in MinIO on 245, which stays
    # private, so uploads and file views work on the LAN and the tailnet only.
    #
    # This is a different route from mcp-plane.pdlab.dev above. That one holds Pedro's PAT, so it
    # stays a one-person list. Here, each person signs in to Plane as themselves.
    "plane.pdlab.dev" = {
      service       = "http://192.168.50.235:8080"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com", "tsilveri406@gmail.com", "soniasdelgadillo@gmail.com"]
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
  to = module.cloudflare_ingress.cloudflare_dns_record.route["seer.pdlab.dev"]
  id = "${local.cloudflare_zone_id}/553f672178651906b01c66cdca2c9de7"
}

# The Access application audience tag for mcp-lab.pdlab.dev (PET-824). lab-agent checks it
# against the `aud` claim of the Cf-Access-Jwt-Assertion JWT, so a token issued for another
# Access app in the team cannot reach the lab tools. It is an identifier, not a secret.
# configure-pete-bot.yml carries it as lab_agent_access_aud, and the MCP stays off until it does.
output "lab_mcp_subdomain_access_aud" {
  description = "Access application audience tag for mcp-lab.pdlab.dev (PET-824). lab-agent checks it on the Cf-Access-Jwt-Assertion JWT. Set it as lab_agent_access_aud. It is not a secret."
  value       = module.cloudflare_ingress.access_application_auds["mcp-lab.pdlab.dev"]
}

# The Access application audience tag for mcp-media.pdlab.dev. mtrace checks it against the `aud`
# claim of the Cf-Access-Jwt-Assertion JWT. It is an identifier, not a secret.
# configure-media-dash.yml carries it as mtrace_mcp_access_aud, and the MCP door stays off until it does.
output "media_mcp_subdomain_access_aud" {
  description = "Access application audience tag for mcp-media.pdlab.dev. mtrace checks it on the Cf-Access-Jwt-Assertion JWT. Set it as mtrace_mcp_access_aud. It is not a secret."
  value       = module.cloudflare_ingress.access_application_auds["mcp-media.pdlab.dev"]
}

# The Access application audience tag for reports.pdlab.dev (PET-868). pete-bot checks it against
# the `aud` claim of the Cf-Access-Jwt-Assertion JWT. It is an identifier, not a secret.
# configure-pete-bot.yml carries it as pete_bot_weekly_access_aud, and the dashboard stays off
# until it does.
output "weekly_dashboard_access_aud" {
  description = "Access application audience tag for reports.pdlab.dev (PET-868). pete-bot checks it on the Cf-Access-Jwt-Assertion JWT. Set it as pete_bot_weekly_access_aud. It is not a secret."
  value       = module.cloudflare_ingress.access_application_auds["reports.pdlab.dev"]
}
