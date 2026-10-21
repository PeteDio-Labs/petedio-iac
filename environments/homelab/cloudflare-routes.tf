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
    # back in was pure latency and pure attack surface. docker.pdlab.dev is now
    # a plain A record straight to the box — see cloudflare_dns_record.registry
    # below. registry.pdlab.dev is retired outright: it fronted Nexus's web UI,
    # which zot replaces with its own, LAN-only.

    # Co-latro and its admin portal are GONE (PET-366). Both were served from VM-230,
    # which is destroyed; leaving either hostname here would point the tunnel at nothing.
    # Removing admin.pdlab.dev also destroys its Access application and policy, and with
    # it the last consumer of the Authentik IdP for a browser-gated route — the IdP stays
    # (cloudflare-oidc.tf) because it is the login path for anything gated later.

    # NOTE: palworld.pdlab.dev MOVED off this tunnel — see module.cloudflare_ingress_palworld
    # at the bottom of this file. Its connector now runs on the game host itself so the panel
    # can bind loopback only (PET-266).

    # Plane MCP, reachable from the phone (PET-292), at pdlab.dev/mcp/plane since PET-667.
    # Every MCP server lives under pdlab.dev/mcp/<name>, one path route and one Access app
    # each. The lab connector (/mcp/lab) joins as a sibling, never behind Plane. PET-667
    # retired the first home of this route, mcp.pdlab.dev, once the connector moved here.
    #
    # Managed OAuth gates an MCP client that speaks OAuth and never renders a page, unlike the
    # browser-gated routes above.
    #
    # Origin is the Caddy shim on plane-235 (:8790), not the MCP server itself. Caddy
    # maps /mcp/plane to the server's /http/api-key mount and swaps Claude's opaque Access
    # token for the Plane PAT. That mount wants the PAT in a header, and it is the only mount
    # that runs no OAuth of its own, which is what Managed OAuth requires of an origin.
    #
    # Why the origin is a LAN address and not loopback: cloudflared runs on LXC 112, a
    # DIFFERENT host, so a 127.0.0.1 bind on 235 would be unreachable. Caddy checks no
    # Access JWT, so the origin firewall on 235 (plane-mcp-firewall.service) is the
    # boundary: it admits only 112 to :8790 and to each member's port. The MCP server itself
    # is never published; only Caddy reaches it.
    #
    # access_emails is the WHOLE authorization boundary here. The shim holds a service PAT,
    # so anyone who passes Access acts as its owner in Plane — keep this list to one person.
    "pdlab.dev/mcp/plane" = {
      hostname      = "pdlab.dev"
      path          = "^/mcp/plane(/.*)?$"
      access_path   = "/mcp/plane"
      service       = "http://192.168.50.235:8790"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]

      managed_oauth = {
        # Claude's connector callback. This list is the security boundary on dynamic
        # client registration — only these redirect targets can ever be registered.
        allowed_redirect_uris = ["https://claude.ai/api/mcp/auth_callback"]

        # Short-lived tokens, long-lived grant: the phone re-auths silently for a week
        # rather than bouncing to Authentik every 15 minutes.
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # The lab MCP (PET-667): lab-agent's read-only lab tools, for claude.ai project threads.
    # The origin is lab-agent's second listener on media-dash-237 (:3017), a LAN address because
    # cloudflared runs on LXC 112.
    #
    # ⚠ TWO CHECKS AT THE ORIGIN, UNLIKE THE PLANE SHIM. lab-agent admits only 112's address
    # and verifies the Cf-Access-Jwt-Assertion JWT against this app's audience tag and the
    # email below. The lab-mcp allowlist on 237 also drops every other source. Either check
    # alone still holds when the other fails.
    #
    # Every tool is a read, so the route can read the lab and change nothing. It still sees
    # Proxmox and Vault metadata, so access_emails stays one person.
    "pdlab.dev/mcp/lab" = {
      hostname      = "pdlab.dev"
      path          = "^/mcp/lab(/.*)?$"
      access_path   = "/mcp/lab"
      service       = "http://192.168.50.237:3017"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com"]

      managed_oauth = {
        allowed_redirect_uris = ["https://claude.ai/api/mcp/auth_callback"]
        access_token_lifetime = "15m"
        session_duration      = "168h"
      }
    }

    # Tom's Plane MCP (PET-610), a copy of pdlab.dev/mcp/plane with a different origin port and email.
    # The origin is the :8791 site of the same Caddy shim, which swaps in Tom's PAT from
    # kv/services/plane-tom, so every call acts as Tom and Plane enforces his roles. The same
    # rule applies as above: access_emails is the whole boundary, so keep it to Tom alone, and
    # keep pdlab.dev/mcp/plane to Pedro alone.
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

    # petedio-usaa (PET-590), the savings and trip tracker on usaa-238. The origin is a LAN
    # address because cloudflared runs on LXC 112, a different host. Access is the gate, with
    # the Authentik IdP, and the two emails are the whole allow-list: Pedro and Sonia.
    # PET-599 renamed both hostnames from usaa to savings; the moved blocks below keep the
    # Access application, and so its audience tag.
    "savings.pdlab.dev" = {
      service       = "http://192.168.50.238:8080"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com", "soniasdelgadillo@gmail.com"]
    }

    # The Plane board (PET-610), so Tom can work in it from outside the lab. The origin is
    # Plane's own proxy on plane-235, a LAN address because cloudflared runs on LXC 112.
    # Access is the gate, with the Authentik IdP, and the emails are the whole allow-list:
    # Pedro, Tom and Sonia (PET-650). Only the app is routed. Attachments live in MinIO on 245, which stays
    # private, so uploads and file views work on the LAN and the tailnet only.
    #
    # This is a different route from pdlab.dev/mcp/plane above. That one holds Pedro's PAT, so it
    # stays a one-person list. Here, each person signs in to Plane as themselves.
    "plane.pdlab.dev" = {
      service       = "http://192.168.50.235:8080"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["pedelgadillo@gmail.com", "tsilveri406@gmail.com", "soniasdelgadillo@gmail.com"]
    }

    # Batsy (Sonia's agent) and Muse (Pedro's) post account totals here from outside the
    # lab and read the month view (PET-590), so Access is OFF for this hostname and the app's
    # bearer check (kv/services/usaa <agent>_bearer_token) is the gate. Only these two paths
    # are routed. The ingress rule matches hostname AND path, so every other path on this
    # hostname falls through to the tunnel's catch-all 404, and the app also refuses
    # non-feed paths on this Host. `path` is a regex, hence the anchors.
    "savings-feed.pdlab.dev" = {
      service = "http://192.168.50.238:8080"
      path    = "^/api/v1/(totals|month)$"
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

# PET-599: rename the savings tracker's hostnames in place. Without these, the apply destroys
# and recreates each resource. A recreated Access application mints a different audience tag,
# and the app rejects every JWT until deploy-usaa.sh lands the new one.
moved {
  from = module.cloudflare_ingress.cloudflare_zero_trust_access_application.route["usaa.pdlab.dev"]
  to   = module.cloudflare_ingress.cloudflare_zero_trust_access_application.route["savings.pdlab.dev"]
}
moved {
  from = module.cloudflare_ingress.cloudflare_zero_trust_access_policy.route["usaa.pdlab.dev"]
  to   = module.cloudflare_ingress.cloudflare_zero_trust_access_policy.route["savings.pdlab.dev"]
}
moved {
  from = module.cloudflare_ingress.cloudflare_dns_record.route["usaa.pdlab.dev"]
  to   = module.cloudflare_ingress.cloudflare_dns_record.route["savings.pdlab.dev"]
}
moved {
  from = module.cloudflare_ingress.cloudflare_dns_record.route["usaa-feed.pdlab.dev"]
  to   = module.cloudflare_ingress.cloudflare_dns_record.route["savings-feed.pdlab.dev"]
}

# ============================================================================================
# Palworld panel — its own tunnel, connector ON the game host (PET-266 lockdown)
# ============================================================================================
#
# WHY A SECOND TUNNEL. The panel binds 127.0.0.1 now, so whatever serves palworld.pdlab.dev
# has to be ON palworld-mc. Ingress config is per-TUNNEL, not per-connector: a rule pointing
# at http://127.0.0.1:8080 applies to EVERY connector on that tunnel, so adding a second
# connector to the main tunnel would make the .50 connector start 502'ing this hostname (it
# has nothing on its own :8080). A dedicated tunnel keeps each connector's ingress honest.
#
# Cloudflare Access is HOSTNAME-scoped, not tunnel-scoped, so the Authentik gate and the
# sonia+pedro allow-list ride along unchanged — same module, same arguments as before.
#
# The tunnel UUID is a REQUIRED variable (no default) — see variables.tf. It used to be
# count-guarded for convenience, but a disabled module plus the `moved` blocks below reads
# as "source removed" and destroys the live Access app + CNAME. Hard-failing the plan on a
# missing ID is the safe outcome; there is no benign version of that apply.
module "cloudflare_ingress_palworld" {
  source = "../../modules/cloudflare-ingress"

  account_id   = local.cloudflare_account_id
  zone_id      = local.cloudflare_zone_id
  tunnel_id    = var.cloudflare_palworld_tunnel_id
  tunnel_cname = "${var.cloudflare_palworld_tunnel_id}.cfargotunnel.com"

  routes = {
    # Origin is loopback ON the connector's own host. The panel serves the SPA + /api + SSE
    # from one Bun process; it has no auth of its own, so Access IS the gate for the web
    # path, and the loopback bind is what stops the play segment bypassing it entirely.
    # The panel can power the game server off/on — keep this list tight: sonia + pedro.
    "palworld.pdlab.dev" = {
      service       = "http://127.0.0.1:8080"
      access        = true
      allowed_idps  = [cloudflare_zero_trust_access_identity_provider.authentik.id]
      access_emails = ["soniasdelgadillo@gmail.com", "pedelgadillo@gmail.com"]
    }
  }
}

# Migrate the LIVE Access application, its policy, and the CNAME between module instances
# rather than letting TF destroy + recreate them. Without these, an apply would tear down the
# Access app on a public hostname and rebuild it — a window where palworld.pdlab.dev resolves
# ungated, plus a new app ID for no reason. `moved` makes it a state rename: zero API churn.
moved {
  from = module.cloudflare_ingress.cloudflare_zero_trust_access_application.route["palworld.pdlab.dev"]
  to   = module.cloudflare_ingress_palworld.cloudflare_zero_trust_access_application.route["palworld.pdlab.dev"]
}
moved {
  from = module.cloudflare_ingress.cloudflare_zero_trust_access_policy.route["palworld.pdlab.dev"]
  to   = module.cloudflare_ingress_palworld.cloudflare_zero_trust_access_policy.route["palworld.pdlab.dev"]
}
moved {
  from = module.cloudflare_ingress.cloudflare_dns_record.route["palworld.pdlab.dev"]
  to   = module.cloudflare_ingress_palworld.cloudflare_dns_record.route["palworld.pdlab.dev"]
}

# ============================================================================================
# Registry DNS — docker.pdlab.dev straight to the box, no tunnel
# ============================================================================================
#
# zot (which replaced Nexus on CT106) serves the OCI API on :443 with a real
# Let's Encrypt cert obtained by DNS-01. So the hostname needs to resolve, but
# nothing needs to PROXY it — hence a plain A record with proxied = false.
#
# WHY KEEP THE HOSTNAME AT ALL instead of using the IP: `docker.pdlab.dev` is
# baked into both co-latro CI workflows, the frontend e2e compose file,
# deploy-lab-graph.sh, lab-graph's stack.yml, and faasd's
# /var/lib/faasd/.docker/config.json. Keeping the name means the registry swap
# touches none of them.
#
# This publishes a private RFC1918 address in public DNS. That is intentional
# and is the normal trade for LAN-only services that still want a real cert: the
# record is only useful to something already on the LAN, and the alternative
# (internal-CA certs) means distributing a CA to every client forever.
resource "cloudflare_dns_record" "registry" {
  zone_id = local.cloudflare_zone_id
  name    = "docker.pdlab.dev"
  type    = "A"
  content = "192.168.50.111"
  ttl     = 300
  proxied = false # MUST stay false — proxying an RFC1918 origin cannot work.
  comment = "zot OCI registry on CT106. LAN-only; no tunnel (PET-122 follow-up)."

  # The old CNAME (tunnel) for this name is destroyed when it leaves the
  # cloudflare_ingress routes map. Cloudflare rejects two records on one name,
  # so the destroy must land first.
  depends_on = [module.cloudflare_ingress]
}

# The Access application audience tag for pdlab.dev/mcp/lab (PET-667). lab-agent checks it
# against the `aud` claim of the Cf-Access-Jwt-Assertion JWT, so a token issued for another
# Access app in the team cannot reach the lab tools. It is an identifier, not a secret.
# configure-pete-bot.yml carries it as lab_agent_access_aud, and the MCP stays off until it does.
output "lab_mcp_access_aud" {
  description = "Access application audience tag for pdlab.dev/mcp/lab, which lab-agent checks on the Cf-Access-Jwt-Assertion JWT. It is not a secret."
  value       = module.cloudflare_ingress.access_application_auds["pdlab.dev/mcp/lab"]
}
