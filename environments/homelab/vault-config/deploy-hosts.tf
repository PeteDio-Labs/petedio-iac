# Host deploys from GitHub Actions: one Vault identity and one SSH certificate role per deploy.
#
# WHY. Six host configurations ran by hand: an operator started a script that read Vault and
# opened SSH with the shared kv/iac/lxc-ssh key, which is root on every Terraform LXC (audit H6).
# Each `deploy-<name>.yml` workflow in this repo replaces one script. It logs in to Vault through
# GitHub OIDC, reads only that deploy's secrets, signs a 30-minute SSH certificate for one
# principal, and connects to one host with it. The pattern is petedio-search's deploy.yml
# (search-cd, search-deploy) applied to the hosts below.
#
# WHAT IS NOT HERE. claude-247 already deploys through ansible-claude-247.yml (claude-247-deploy,
# ssh.tf is unchanged for it). uptime-kuma and vault-unseal stay by hand: docs/runbooks/host-deploys.md
# says why.
#
# ONE APPLY. Every role, policy and signing role below lands in one `apply-vault-config.sh` run.
# Each host must also trust the CA and list its principal before a workflow can log in. Run
# configure-ssh-ca-deploy-hosts.yml through lab-action.yml for that (docs/runbooks/host-deploys.md).

locals {
  # name: the workflow file deploy-<name>.yml, the kv paths its script read, and the SSH role the
  # job signs. Every deploy has its own role and principal. backup-store does not reuse
  # lab-runner: that principal is root on the nodes and lab-action.yml gates every write behind
  # the lab-write tap, so a dispatch-only deploy must not sign it. The nodes list
  # deploy-backup-store in group_vars, written by configure-ssh-ca-deploy-hosts.yml.
  host_deploys = {
    plane = {
      kv = [
        "db/plane",
        "services/plane",
        "services/plane-claude",
        "services/plane-tom",
        "services/plane-sonia",
      ]
      sign = "deploy-plane"
    }
    "minio-data" = {
      kv   = ["iac/minio-data-root"]
      sign = "deploy-minio-data"
    }
    metrics = {
      kv   = ["services/lab-watchdog"]
      sign = "deploy-metrics"
    }
    "lab-watchdog" = {
      kv   = ["services/lab-watchdog", "services/aws-watchdog"]
      sign = "deploy-lab-watchdog"
    }
    "codex-248" = {
      kv = [
        "services/codex-review-app",
        "services/codex-plane",
        "services/pete-bot",
      ]
      sign = "deploy-codex-248"
    }
    "backup-store" = {
      kv   = ["services/backup-health"]
      sign = "deploy-backup-store"
    }
    # The portfolio staging host (staging-249) mints its own read-only GitHub App token to pull the
    # portfolio's `staging` branch. It holds a dedicated App installed on pdlabs-portfolio alone,
    # not the workspace-mirror App: the host runs branch code, and a key on it must not reach
    # petedio-vault (scripts/seed-staging-app-vault.sh proves the scope before it writes).
    "staging-249" = {
      kv   = ["services/staging-app"]
      sign = "deploy-staging-249"
    }
  }

  # The signing roles to create, one per deploy.
  host_deploy_ssh_roles = toset([for d in values(local.host_deploys) : d.sign])
}

# One signing role per deploy host. Same shape as search-deploy in ssh.tf: the principal is the
# role name, the certificate works only from runners 232 and 233, lives 30 minutes, and carries
# no pty and no forwarding. The host decides which user accepts the principal (root's principals
# file, written by configure-ssh-ca-deploy-hosts.yml).
resource "vault_ssh_secret_backend_role" "host_deploy" {
  for_each = local.host_deploy_ssh_roles

  backend  = vault_mount.ssh_client_signer.path
  name     = each.value
  key_type = "ca"

  depends_on = [vault_policy.breakglass_247]

  allow_user_certificates = true
  allowed_users           = each.value
  default_user            = each.value
  allow_user_key_ids      = false

  allowed_extensions = ""
  default_extensions = {}

  # The same sentinel as inventory-read, for the same reason: no request can drop the default.
  allowed_critical_options = "petedio-no-overrides"
  default_critical_options = {
    "source-address" = "192.168.50.232/32,192.168.50.233/32"
  }

  ttl     = "1800"
  max_ttl = "1800"

  allowed_user_key_config {
    type    = "ed25519"
    lengths = [0]
  }
}

# Reads exactly the paths the deploy's script read, and signs exactly one role. An optional path
# that is absent is a supported state, so read on a missing path is not an error in Vault.
resource "vault_policy" "host_deploy" {
  for_each = local.host_deploys

  name = "deploy-${each.key}"

  policy = join("\n", concat(
    [for p in each.value.kv : "path \"kv/data/${p}\" {\n  capabilities = [\"read\"]\n}\n"],
    ["path \"${vault_mount.ssh_client_signer.path}/sign/${each.value.sign}\" {\n  capabilities = [\"update\"]\n}\n"],
  ))
}

# Bound to the workflow file and to workflow_dispatch, as claude-247-deploy is: a push, a
# schedule or a pull request cannot mint the token, and no other workflow can either.
resource "vault_jwt_auth_backend_role" "host_deploy" {
  for_each = local.host_deploys

  backend           = vault_jwt_auth_backend.github.path
  role_name         = "deploy-${each.key}"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/deploy-${each.key}.yml@refs/heads/main"
  }
  token_policies = [vault_policy.host_deploy[each.key].name]
  token_ttl      = 900
}
