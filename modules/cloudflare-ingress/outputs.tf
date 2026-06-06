output "tunnel_config_id" {
  description = "ID of the tunnel ingress configuration."
  value       = cloudflare_zero_trust_tunnel_cloudflared_config.this.id
}

output "dns_records" {
  description = "Map of hostname -> created proxied CNAME record id."
  value       = { for h, r in cloudflare_dns_record.route : h => r.id }
}

output "access_application_ids" {
  description = "Map of gated hostname -> Cloudflare Access application id."
  value       = { for h, a in cloudflare_zero_trust_access_application.route : h => a.id }
}
