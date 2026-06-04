# Least-privilege policies for the KV v2 engine (mounts.tf). KV v2 splits the API:
# secret values live under kv/data/<path> and listing/metadata under
# kv/metadata/<path>. All three policies are READ + LIST only — no create/update/
# delete — so a leaked token can read scoped secrets but never mutate the store.

# ci-read: the policy GitHub Actions gets via the JWT/OIDC role. Narrow read scope
# limited to the secrets CI actually needs (Proxmox/MinIO/LXC-SSH creds + poker app).
resource "vault_policy" "ci_read" {
  name = "ci-read"

  policy = <<-EOT
    path "kv/data/iac/proxmox" {
      capabilities = ["read"]
    }

    path "kv/data/iac/minio" {
      capabilities = ["read"]
    }

    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/iac/cloudflare" {
      capabilities = ["read"]
    }

    path "kv/data/poker/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/*" {
      capabilities = ["list"]
    }
  EOT
}

# terraform: local/CI Terraform runs read all infra + poker secrets.
resource "vault_policy" "terraform" {
  name = "terraform"

  policy = <<-EOT
    path "kv/data/iac/*" {
      capabilities = ["read"]
    }

    path "kv/data/poker/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/*" {
      capabilities = ["list"]
    }
  EOT
}

# colatro-ci: the policy the Co-latro app repos get via the colatro-ci JWT role
# (auth.tf). Least-privilege for publish-on-merge + the manual deploy workflow:
#   - kv/services/nexus            push the backend image to Nexus
#   - kv/services/minio-frontend-ci  WRITE the frontend dist to the MinIO bucket
#     (distinct from the read-only kv/services/minio-frontend the on-box rollout uses)
#   - kv/iac/lxc-ssh               SSH key to reach LXC 230 from the deploy workflow
# Deliberately NOT kv/poker/* (the DB env-file is rendered on the box by the one-time
# Ansible rollout — publish/deploy CI never needs DATABASE_URL) and NOT kv/iac/* beyond
# the SSH key.
resource "vault_policy" "colatro_ci" {
  name = "colatro-ci"

  policy = <<-EOT
    path "kv/data/services/nexus" {
      capabilities = ["read"]
    }

    path "kv/data/services/minio-frontend-ci" {
      capabilities = ["read"]
    }

    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/metadata/*" {
      capabilities = ["list"]
    }
  EOT
}

# ansible: host-config runs read infra + service secrets.
resource "vault_policy" "ansible" {
  name = "ansible"

  policy = <<-EOT
    path "kv/data/iac/*" {
      capabilities = ["read"]
    }

    path "kv/data/services/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/*" {
      capabilities = ["list"]
    }
  EOT
}
