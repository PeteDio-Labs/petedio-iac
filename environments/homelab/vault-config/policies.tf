# Least-privilege policies for the KV v2 engine (mounts.tf). KV v2 splits the API:
# secret values live under kv/data/<path> and listing/metadata under
# kv/metadata/<path>. All three policies are READ + LIST only — no create/update/
# delete — so a leaked token can read scoped secrets but never mutate the store.
#
# PET-112: each policy's kv/metadata LIST grant is scoped to the SAME top-level
# prefixes it can read (iac/poker/admin/services), not a blanket kv/metadata/*.
# A blanket grant let any leaked CI token enumerate every secret PATH NAME across
# tenants (e.g. `vault kv list kv/` showing poker/admin/services). Per-prefix list
# keeps same-tenant listing working while removing cross-tenant name enumeration;
# `vault kv list kv/` (= LIST kv/metadata/) is no longer permitted.

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

    path "kv/data/iac/authentik" {
      capabilities = ["read"]
    }

    path "kv/data/poker/*" {
      capabilities = ["read"]
    }

    path "kv/data/admin/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/poker/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/admin/*" {
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

    path "kv/data/admin/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/poker/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/admin/*" {
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

    path "kv/metadata/services/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/iac/*" {
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

    path "kv/data/admin/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/services/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/admin/*" {
      capabilities = ["list"]
    }
  EOT
}

# media-ci: the policy the petedio-media-iac GitHub Actions gets via its own JWT/
# OIDC role (auth.tf, role media-ci). Scoped to exactly what media TF init/plan +
# Ansible need: the shared iac backend/provider creds (minio/proxmox/lxc-ssh) and
# the media-only service secret. NOT given poker/* or cloudflare/* — those are
# unrelated to the media stack.
resource "vault_policy" "media_ci" {
  name = "media-ci"

  policy = <<-EOT
    path "kv/data/iac/minio" {
      capabilities = ["read"]
    }

    path "kv/data/iac/proxmox" {
      capabilities = ["read"]
    }

    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/media/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/services/media/*" {
      capabilities = ["list"]
    }
  EOT
}

# openfaas-ci: the petedio-iac CI role that APPLIES configure-openfaas.yml to LXC 241 on
# merge (the runner SSHes in). Least-privilege: ONLY the ansible SSH key (to reach 241) and
# the Nexus pull creds (written into faasd's /var/lib/faasd/.docker/config.json). NOT the
# broader ci-read/iac scope. (PET-88)
resource "vault_policy" "openfaas_ci" {
  name = "openfaas-ci"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/nexus" {
      capabilities = ["read"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/services/*" {
      capabilities = ["list"]
    }
  EOT
}

# palworld-panel-cd: the petedio-palworld-panel repo's CD role — deploy.yml runs the native
# panel play against LXC 234 on merge (the runner SSHes in). Least-privilege: ONLY the ansible
# SSH key (to reach 234) and the panel's own service secret (REST admin password + restricted
# start-hook key). NOT the broader ci-read/ansible scope. (PET-266)
resource "vault_policy" "palworld_panel_cd" {
  name = "palworld-panel-cd"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/palworld-panel" {
      capabilities = ["read"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/services/*" {
      capabilities = ["list"]
    }
  EOT
}

# vault-snapshot: the policy the automated raft-snapshot timer on .223 uses (PET-109).
# Exactly two narrow reads — take a raft snapshot, and read the MinIO svcacct creds it
# uploads with. Nothing else: a leaked snapshot token can back Vault up and read the
# snapshot-upload creds, but cannot read any app/infra secret in kv/.
resource "vault_policy" "vault_snapshot" {
  name = "vault-snapshot"

  policy = <<-EOT
    # Take an integrated-storage (raft) snapshot.
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }

    # Read the scoped MinIO svcacct creds used to upload the snapshot to the
    # vault-snapshots bucket (seeded out-of-band by the operator — see the runbook).
    path "kv/data/services/vault-snapshots" {
      capabilities = ["read"]
    }
  EOT
}

# poker-api: the policy the Vault Agent on the poker-api host (LXC 230) gets (PET-57). It
# reads ONLY kv/poker/db — the app's own DATABASE_URL — so the Agent can render the backend
# env-file to tmpfs at runtime. Strictly narrower than terraform/ci-read (all poker/*); a
# leaked 230 token reads its own DB URL and nothing else.
resource "vault_policy" "poker_api" {
  name = "poker-api"

  policy = <<-EOT
    path "kv/data/poker/db" {
      capabilities = ["read"]
    }
  EOT
}
