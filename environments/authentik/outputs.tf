output "instance_id" {
  description = "The host. Open a shell with: aws ssm start-session --target <id>."
  value       = aws_instance.host.id
}

output "bucket" {
  description = "Config, migration dump and nightly backups. scripts/seed-authentik-aws.sh writes the dump here."
  value       = aws_s3_bucket.this.bucket
}

output "parameter_prefix" {
  description = "SSM Parameter Store prefix the host reads: env, tunnel_token and the optional tailscale_authkey."
  value       = local.param_prefix
}

output "authentik_version" {
  description = "The image tag the host runs. It must match the lab copy while both exist."
  value       = var.authentik_version
}

output "accept_restore" {
  description = "Whether the host still accepts a database copy from the lab."
  value       = var.accept_restore
}
