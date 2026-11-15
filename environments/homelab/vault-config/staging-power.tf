# On-demand staging (staging-249): the Vault side of .github/workflows/staging-power.yml.
#
# The workflow starts and stops CT 249 on pve03 from the LAN runner. It needs three things from Vault:
#   1. an SSH certificate whose command is FIXED to /usr/local/sbin/staging-power on the node, which
#      accepts only status, start and stop for container 249 (ansible/playbooks/files/staging-power-node.sh),
#   2. read access to kv/services/staging-app, the read-only GitHub App that reads the portfolio's
#      `staging` branch, and
#   3. a login that only this workflow, on main, can mint, on a schedule or a dispatch.
#
# The certificate carries `force-command`, so the caller cannot ask for another command. The
# allowed_critical_options sentinel means a signing request cannot override or drop the defaults,
# the same device the deploy roles use for source-address.
#
# ⚠ THE NODE MUST LIST THE PRINCIPAL. group_vars/pve_new.yml names staging-power, and
# configure-ssh-ca-deploy-hosts.yml writes it into root's principals file on pve03.

resource "vault_ssh_secret_backend_role" "staging_power" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "staging-power"
  key_type = "ca"

  depends_on = [vault_policy.breakglass_247]

  allow_user_certificates = true
  allowed_users           = "staging-power"
  default_user            = "staging-power"
  allow_user_key_ids      = false

  allowed_extensions = ""
  default_extensions = {}

  allowed_critical_options = "petedio-no-overrides"
  default_critical_options = {
    "source-address" = "192.168.50.232/32,192.168.50.233/32"
    "force-command"  = "/usr/local/sbin/staging-power"
  }

  ttl     = "1800"
  max_ttl = "1800"

  allowed_user_key_config {
    type    = "ed25519"
    lengths = [0]
  }
}

resource "vault_policy" "staging_power" {
  name = "staging-power"

  policy = <<-EOT
    path "kv/data/services/staging-app" {
      capabilities = ["read"]
    }
    path "${vault_mount.ssh_client_signer.path}/sign/staging-power" {
      capabilities = ["update"]
    }
  EOT
}

# One login role per trigger, because a role binds one event_name. The workflow picks its role as
# staging-power-<event>. Both bind the repository, main and this workflow file, so a push, a pull
# request or any other workflow cannot mint the token.
resource "vault_jwt_auth_backend_role" "staging_power" {
  for_each = toset(["schedule", "workflow_dispatch"])

  backend           = vault_jwt_auth_backend.github.path
  role_name         = "staging-power-${each.key}"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = each.key
    workflow_ref = "${var.github_repo}/.github/workflows/staging-power.yml@refs/heads/main"
  }
  token_policies = [vault_policy.staging_power.name]
  token_ttl      = 900
}
