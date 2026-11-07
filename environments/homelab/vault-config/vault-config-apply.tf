# vault-config-plan and vault-config-apply: the gated path that applies this root from CI.
#
# vault-config stays out of the normal apply-on-merge job on purpose: it holds every policy and
# auth role in the lab. These two roles let .github/workflows/vault-config-apply.yml plan it
# freely and apply it after Pedro approves the `lab-write` environment. Layers, outermost first:
#
#  1. Binding. Each role is bound to the repository, main, workflow_dispatch and that one workflow
#     file. The apply role is also bound to environment lab-write, so Vault refuses it until Pedro
#     approves the job. Both tokens last 10 minutes.
#  2. Guard. scripts/vault-config-guard.py runs in both jobs and refuses deletes, protected
#     addresses and anything that widens access (policies on sys/, auth/ or identity/, privileged
#     policies on a role, ssh roles for root). The apply job re-plans and applies only if the plan
#     digest matches the one the plan job printed.
#  3. This policy. The apply token can create and update policies, JWT roles and ssh roles. It
#     cannot delete anything, and it is denied its own policy and role, the break-glass policy, the
#     userpass and MFA setup, the audit device and the root-principal ssh roles. A Vault `deny`
#     wins over every grant, so the guard does not carry the whole load.
#
# ⚠ THE FIRST APPLY OF THIS FILE IS A MAC STEP. The guard protects these resources, so the gated
# path can never change them; edit them only through scripts/apply-vault-config.sh.
# ⚠ UNTESTED PATH LIST. The paths below come from reading the resources in this root. Run the
# workflow's plan job first: a missing path shows as a 403 naming it, and the fix is one reviewed PR.
locals {
  vc_read_paths = <<-EOT
    path "kv/data/iac/minio" {
      capabilities = ["read"]
    }
    path "sys/policies/acl" {
      capabilities = ["list"]
    }
    path "sys/policies/acl/*" {
      capabilities = ["read", "list"]
    }
    path "sys/auth" {
      capabilities = ["read"]
    }
    path "sys/auth/*" {
      capabilities = ["read"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/*" {
      capabilities = ["read"]
    }
    path "sys/audit" {
      capabilities = ["read"]
    }
    path "auth/*" {
      capabilities = ["read", "list"]
    }
    path "ssh-client-signer/*" {
      capabilities = ["read", "list"]
    }
    path "identity/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_policy" "vault_config_plan" {
  name   = "vault-config-plan"
  policy = local.vc_read_paths
}

resource "vault_policy" "vault_config_apply" {
  name = "vault-config-apply"

  policy = <<-EOT
    ${local.vc_read_paths}

    # Create and update only. No delete, so a bug in the guard still cannot remove a live resource.
    path "sys/policies/acl/*" {
      capabilities = ["create", "update", "read", "list"]
    }
    path "auth/jwt-github/role/*" {
      capabilities = ["create", "update", "read", "list"]
    }
    path "ssh-client-signer/roles/*" {
      capabilities = ["create", "update", "read", "list"]
    }

    # Denied, and a deny wins over every grant above.
    path "sys/policies/acl/vault-config-apply" {
      capabilities = ["deny"]
    }
    path "sys/policies/acl/vault-config-plan" {
      capabilities = ["deny"]
    }
    path "sys/policies/acl/breakglass-247" {
      capabilities = ["deny"]
    }
    path "auth/jwt-github/role/vault-config-apply" {
      capabilities = ["deny"]
    }
    path "auth/jwt-github/role/vault-config-plan" {
      capabilities = ["deny"]
    }
    path "auth/jwt-github/config" {
      capabilities = ["deny"]
    }
    path "auth/userpass/*" {
      capabilities = ["deny"]
    }
    path "identity/mfa/*" {
      capabilities = ["deny"]
    }
    path "sys/audit/*" {
      capabilities = ["deny"]
    }
    path "ssh-client-signer/config/*" {
      capabilities = ["deny"]
    }
    path "ssh-client-signer/roles/lab-runner" {
      capabilities = ["deny"]
    }
    path "ssh-client-signer/roles/pedro" {
      capabilities = ["deny"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "vault_config_plan" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "vault-config-plan"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/vault-config-apply.yml@refs/heads/main"
  }
  token_policies = [vault_policy.vault_config_plan.name]
  token_ttl      = 600
  token_max_ttl  = 600
}

# The environment claim is what makes Pedro's approval a Vault requirement, not only a GitHub one.
resource "vault_jwt_auth_backend_role" "vault_config_apply" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "vault-config-apply"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    environment  = "lab-write"
    workflow_ref = "${var.github_repo}/.github/workflows/vault-config-apply.yml@refs/heads/main"
  }
  token_policies = [vault_policy.vault_config_apply.name]
  token_ttl      = 600
  token_max_ttl  = 600
}
