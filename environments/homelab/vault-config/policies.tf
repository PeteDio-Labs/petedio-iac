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
    # water-fast (LXC 243). Scoped to the single secret, NOT kv/data/services/* — CI only
    # needs this one, and the wider prefix would hand every service's credentials to the
    # apply job. Required before var.waterfast_db_ready can flip to true: the gated
    # ephemeral read in waterfast.tf runs as ci-read on apply-on-merge, and without this
    # grant that apply fails with a permission denied on a path it can see but not read.
    path "kv/data/services/water-fast" {
      capabilities = ["read"]
    }

    # plane (LXC 235). Same single-secret scoping as water-fast above: the gated
    # ephemeral read in databases.tf runs as ci-read on apply-on-merge, so without this
    # grant the apply fails with a permission denied on a path it can SEE but not read.
    # This must land BEFORE the merge that adds `plane = {}` to databases.tf.
    path "kv/data/db/plane" {
      capabilities = ["read"]
    }

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

    path "kv/metadata/db/*" {
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
#   - kv/services/registry         push the backend image to the registry (zot)
#   - kv/services/minio-frontend-ci  WRITE the frontend dist to the MinIO bucket
#     (distinct from the read-only kv/services/minio-frontend the on-box rollout uses)
#   - kv/iac/lxc-ssh               SSH key to reach LXC 230 from the deploy workflow
# Deliberately NOT kv/poker/* (the DB env-file is rendered on the box by the one-time
# Ansible rollout — publish/deploy CI never needs DATABASE_URL) and NOT kv/iac/* beyond
# the SSH key.
resource "vault_policy" "colatro_ci" {
  name = "colatro-ci"

  policy = <<-EOT
    path "kv/data/services/registry" {
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

# colatro-admin-ci: the policy the co-latro-admin repo gets via the colatro-admin-ci JWT role
# (auth.tf, PET-99). Least-privilege for the deploy-on-merge workflow (Workflow B) that builds
# the 4 OpenFaaS functions, pushes them to Nexus, and `faas-cli deploy`s them to faasd (LXC 241):
#   - kv/admin/db            DATABASE_URL wired into every function's env (stack.yml)
#   - kv/services/admin      the co-latro <-> admin seam token (users fn: COLATRO_SERVICE_TOKEN)
#   - kv/services/openfaas   the faasd gateway password (`faas-cli login`)
#   - kv/services/registry   push the 4 function images to Nexus (docker login). The path is
#                            `registry`, NOT `nexus` — see ansible-stack.yml and colatro_ci.
#   - kv/iac/lxc-ssh         SSH key to open the runner->241:8080 tunnel for the deploy
#   - kv/poker/db            INVITES_TOKEN (the invites-fn Bearer secret; optional at rollout)
# READ + per-prefix LIST only — a leaked token reads exactly these deploy inputs and mutates
# nothing. Scoped tighter than the `ansible` policy (all services/*); no iac/* beyond the SSH key.
resource "vault_policy" "colatro_admin_ci" {
  name = "colatro-admin-ci"

  policy = <<-EOT
    path "kv/data/admin/db" {
      capabilities = ["read"]
    }

    path "kv/data/services/admin" {
      capabilities = ["read"]
    }

    path "kv/data/services/openfaas" {
      capabilities = ["read"]
    }

    path "kv/data/services/registry" {
      capabilities = ["read"]
    }

    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/poker/db" {
      capabilities = ["read"]
    }

    path "kv/metadata/admin/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/services/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/poker/*" {
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

    # kv/db/* — the per-database owner passwords declared in databases.tf.
    #
    # WHY ANSIBLE NEEDS THIS AT ALL. Until Plane, every database password was consumed
    # only by Terraform (ci-read) — Ansible never rendered a connection string, because
    # the apps holding one either got it from a kv/services/<app> secret or built it on
    # the box. configure-plane.yml is the first play to render a DATABASE_URL, so
    # scripts/deploy-plane.sh must read kv/db/plane under this policy. Without it the
    # deploy dies at "permission denied" on a path it can see but not read — the same
    # failure mode the ci-read comment warns about, one policy over.
    #
    # Scoped to the kv/db/ prefix only. It does NOT widen to poker/* or iac/*.
    path "kv/data/db/*" {
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

    path "kv/metadata/db/*" {
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
# the registry pull creds (written into faasd's /var/lib/faasd/.docker/config.json). NOT the
# broader ci-read/iac scope. (PET-88)
resource "vault_policy" "openfaas_ci" {
  name = "openfaas-ci"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/registry" {
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

# water-fast-cd: the petedio-water-fast repo's CD role — deploy.yml copies the built
# frontend + backend source and installs the systemd unit on waterfast-243 on merge (the
# runner SSHes in). Least-privilege: ONLY the ansible SSH key (to reach 243) and the app's
# own service secret (DB password + CF Access team domain/AUD). NOT the broader
# ci-read/ansible scope. Mirrors resume-builder-cd. Apply BEFORE the CD workflow lands or
# the first run 403s.
resource "vault_policy" "water_fast_cd" {
  name = "water-fast-cd"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/water-fast" {
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

# resume-builder-cd: the petedio-resume-builder repo's CD role (Resume Builder P1) —
# deploy.yml copies build/ + installs the systemd unit on resume-242 on merge (the runner
# SSHes in). Least-privilege: ONLY the ansible SSH key (to reach resume-242) and the app's
# own service secret (Mongo creds + CF Access env). NOT the broader ci-read/ansible scope.
# Mirrors palworld-panel-cd. Apply BEFORE the CD workflow lands or the first run 403s.
resource "vault_policy" "resume_builder_cd" {
  name = "resume-builder-cd"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/resume-builder" {
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

# plane-ci: the ONLY policy a PR-triggered run may hold. Deliberately one path.
#
# WHY IT IS THIS NARROW. plane-sync.yml runs on `pull_request_target`, whose OIDC
# subject (`...:pull_request`) is the SAME one an ordinary `pull_request` presents —
# so a PR can mint this token. PET-104 removed that subject from ci-read precisely
# because ci-read reaches Proxmox, MinIO, Cloudflare and Authentik. This policy is
# the safe counterpart: its entire blast radius is "can change a work item's state
# and post a comment".
#
# ⚠️ NEVER add a second path here, and never attach ci-read to the plane-ci role.
# The moment this policy can read anything infrastructural, PET-104's exposure is
# back and it is reachable from any fork's pull request.
resource "vault_policy" "plane_ci" {
  name = "plane-ci"

  policy = <<-EOT
    path "kv/data/services/plane" {
      capabilities = ["read"]
    }
  EOT
}
