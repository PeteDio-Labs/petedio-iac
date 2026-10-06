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
# limited to the secrets CI actually needs (Proxmox/MinIO/LXC-SSH creds + kv/poker/db).
#
# ⚠ THE kv/poker/* GRANTS BELOW STAY, THOUGH CO-LATRO IS GONE (PET-366). They do not
# serve the poker app any more — they serve the postgresql PROVIDER, whose server-wide
# admin credential still lives at kv/poker/db under that historical name. Revoking them
# as teardown tidying would leave CI unable to plan against postgres-231 at all.
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

    # usaa (LXC 238, PET-590). The same gated read as plane, for `usaa = {}` in
    # databases.tf. Apply this, and seed kv/db/usaa with scripts/seed-usaa-db.sh, BEFORE
    # the merge that adds that entry, or its apply-on-merge fails on this path.
    path "kv/data/db/usaa" {
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

    # ⚠ EXCEPT the dashboard's own secret, which is NOT a media-stack credential.
    # kv/services/media/dashboard holds mtrace's dedicated SSH private key (PET-355), and
    # that key is root on six media containers. The glob above was written before anything
    # existed under this prefix, so seeding the dashboard there silently widened media-ci
    # from "read the media stack's secrets" to "hold root on the media stack".
    #
    # Vault resolves the MOST SPECIFIC path first — an exact match beats a glob — so this
    # deny wins over the rule above it regardless of ordering. Verified against a live
    # token carrying this policy, not assumed.
    path "kv/data/services/media/dashboard" {
      capabilities = ["deny"]
    }

    path "kv/metadata/iac/*" {
      capabilities = ["list"]
    }

    path "kv/metadata/services/media/*" {
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

# media-dash-cd: the petedio-media-control repo's CD role (PET-355) — deploy.yml compiles
# the mtrace binary and installs it plus its systemd unit on media-dash-237 on merge (the
# runner SSHes in). Least-privilege: ONLY the ansible SSH key (to reach 237) and the app's
# own service secret. Mirrors water-fast-cd. Apply BEFORE the CD workflow lands or the
# first run 403s.
#
# ⚠ IT IS DELIBERATELY NOT GIVEN THE *arr API KEYS, and that is the whole security story
# of PET-355. The ticket budgeted for holding seven credentials centrally; the transport
# that shipped does not need them, because the curl runs ON each host — a key is read from
# that host's own config, used on its own loopback, and only the RESPONSE crosses the LAN.
# Centralising them would have been a REGRESSION bought with this ticket's own budget.
#
# ⚠ And it could never have been complete anyway: qBittorrent's WebUI is unreachable from
# off-box no matter what credential you hold. Docker SNATs host-origin traffic to the
# bridge gateway, which falls outside `WebUI\AuthSubnetWhitelistEnabled`, so the only way
# in is `docker exec` inside the netns — over SSH. A design that put the *arr keys in Vault
# would still have needed the SSH key for the download client.
#
# So the one credential held centrally is the one that genuinely exists: the SSH key, plus
# the dashboard's own API token.
# pete-bot-cd: the Discord surface's deploy (PET-375). Narrower than media-dash-cd on
# purpose — pete-bot reads only its own credentials, and nothing else.
#
# ⚠ pete-bot-cd no longer reads kv/data/services/media/dashboard. That path held mtrace's
# whole secret, api_token included, so this role could also read mtrace's SSH private key —
# root on six media hosts. pete-bot#26 drops every mtrace call, so PET-518 drops the read.
resource "vault_policy" "pete_bot_cd" {
  name = "pete-bot-cd"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/pete-bot" {
      capabilities = ["read"]
    }

    path "kv/metadata/services/pete-bot" {
      capabilities = ["list"]
    }
  EOT
}

# media-updates: what pete-bot's update workflow may read (PET-395). The Ansible SSH key
# and nothing else: not MinIO, not Proxmox, not mtrace's key. media-ci carries those for
# Terraform; an update run needs none of them.
resource "vault_policy" "media_updates" {
  name = "media-updates"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "media_dash_cd" {
  name = "media-dash-cd"

  policy = <<-EOT
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/services/media/dashboard" {
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

# infra-reconcile: reads the cluster and files drift as work items (PET-294).
#
# This is deliberately NOT a second path on plane-ci. The warning above is exact —
# plane-ci is mintable from a `pull_request` subject, so anything infrastructural
# added there is reachable from a fork's PR, which is precisely the PET-104 exposure.
#
# The safe counterpart is a separate policy on a MAIN-ONLY role: the reconciler runs
# from `schedule` on petedio-vault's default branch, whose subject
# (`...:ref:refs/heads/main`) no fork can present. Same split plane-reconcile relies on.
#
# Blast radius: read the Proxmox token (which is itself read-only against the cluster)
# and the Plane PAT. It cannot write to either — the reconciler files work items and
# never touches infrastructure.
resource "vault_policy" "infra_reconcile" {
  name = "infra-reconcile"

  policy = <<-EOT
    path "kv/data/iac/proxmox" {
      capabilities = ["read"]
    }
    path "kv/data/services/plane" {
      capabilities = ["read"]
    }
  EOT
}

# openfaas-ci — ⚠ THE NAME IS STALE, THE ROLE IS LIVE (PET-423).
#
# openfaas-241 was destroyed on 2026-09-12 (PET-403/404) and nothing declares it any more.
# This policy is NOT dead with it: `.github/workflows/ansible-stack.yml` still mints as the
# `openfaas-ci` role to deploy the ARR STACK. That workflow absorbed the OpenFaaS and
# Palworld workflows and kept the old role name.
#
# It was absent from this config and present in Vault, so the next apply planned to destroy
# it. The plan was refused by scripts/apply-vault-config.sh. Had it gone through, the arr
# stack's next deploy would have failed with a Vault 403 and no visible connection to a
# vault-config apply run hours earlier.
#
# RENAMING IT IS THE REAL FIX and is deliberately not done here: the role and the workflow
# have to move together, with no run in between. Declared as it lives, so that rename is a
# decision rather than an accident.
#
# ⚠ The `kv/data/services/registry` grant below is already dead — registry-106 will not
# restore and its blob store is gone (PET-389). Kept because removing it is a destroy in
# this root and wants its own reviewed plan. Do not tidy it in passing.
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

# claude-247-deploy: what ansible-claude-247.yml may read to deploy 247's claude-code role
# (PET-515). Exact paths, read only: no glob and no list, because the workflow reads named
# fields from named paths and never needs to enumerate anything. The `ansible` AppRole that
# deploy-claude-247.sh uses reads kv/data/services/*; this role reads the six paths below
# and no more. The work loop's App and the Plane PAT left this policy with the loop (PET-547).
resource "vault_policy" "claude_247_deploy" {
  name = "claude-247-deploy"

  policy = <<-EOT
    # The read-only App that delivers petedio-workspace to 247 (PET-493). Optional.
    path "kv/data/services/claude-workspace-mirror" {
      capabilities = ["read"]
    }

    # The App a session on 247 pushes petedio-vault with (PET-498). Optional.
    path "kv/data/services/claude-vault-push" {
      capabilities = ["read"]
    }

    # The App a session on 247 pushes branches and opens PRs with (PET-507). Optional.
    path "kv/data/services/claude-code-push" {
      capabilities = ["read"]
    }

    # claude-ops's own GitHub App, for Pedro's Remote Control sessions (PET-531). Optional.
    path "kv/data/services/claude-ops-github" {
      capabilities = ["read"]
    }

    # 247's PVEAuditor token for the Proxmox API (PET-510). Optional.
    path "kv/data/services/claude-247-pve" {
      capabilities = ["read"]
    }

    # The Ansible SSH key the play reaches 247 with.
    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }
  EOT
}

# claude-ops: the policy behind auth.tf's claude-ops token role, minted by
# scripts/seed-claude-ops-vault-token.sh onto claude-247 for claude-ops, Pedro's Remote
# Control identity (PET-531). READ only, on 27 named secrets — no list, no
# create/update/delete, and no App keys.
#
# Pedro's decision: exact paths, not a wildcard glob, and no `kv/metadata/*` grant either.
# Every `kv/data/<path>` below is one secret the Mac's own scripts already read
# (deploy-claude-247.sh, apply-vault-config.sh, seed-*.sh) or write there — never a GitHub
# App's private key. `vault kv get` on a named path needs no `list`, and nothing in
# `ansible/roles/claude-code` or `scripts/seed-claude-ops-*` calls `vault kv list` or reads
# `kv/metadata/*`, so claude-ops can read exactly these 27 secrets and cannot discover, list
# or enumerate any other name under `services/`, `iac/` or `db/`.
#
# The Mac's seed-* scripts write these paths from the Mac with the admin token;
# deploy-claude-247.sh reads them through its own AppRole login
# (scripts/deploy-claude-247.sh), never the admin token. Neither path goes through this
# policy — this is what claude-ops itself may read once a token minted against it lands on
# 247.
#
# Deliberately excluded by name, and not by omission — each is another App's private key,
# and the separation between the Apps is the point:
#   kv/services/claude-code-push        — the code-push App (PET-507)
#   kv/services/claude-loop             — the retired work loop's App (PET-399, PET-547)
#   kv/services/claude-vault-push       — the vault-push App (PET-498)
#   kv/services/claude-workspace-mirror — the workspace-mirror App (PET-480/493)
#   kv/services/claude-ops-github       — claude-ops's OWN App key. claude-ops reads it from
#                                          disk on 247 (~/.config/claude-ops-github/), never
#                                          from Vault, so it is not in this policy either.
#   kv/services/agent-loop              — the retired agent fleet (PET-265); no session reads it.
#
# A new secret needs a policy change to be readable here, and that is by design: adding a
# path is a reviewable diff, not a standing grant that widens itself.
#
# ⚠ NEVER kv/data/admin/*. Every other broad-scoped policy in this file (ci-read, terraform,
# ansible) reads kv/data/admin/*, but that prefix is where the Vault ROOT TOKEN and the
# unseal material are documented (vault/Systems/vault-and-secrets.md) — exactly what Pedro's
# decision for PET-531 rules out landing on 247 by any path. Granting it here would make a
# renewing token on 247 equivalent to the one credential this whole design exists to keep
# off that host. If a future need requires one specific kv/data/admin/<x> path, add that
# ONE path with its own comment — never widen this to kv/data/admin/*.
resource "vault_policy" "claude_ops" {
  name = "claude-ops"

  policy = <<-EOT
    path "kv/data/db/plane" {
      capabilities = ["read"]
    }

    path "kv/data/iac/authentik" {
      capabilities = ["read"]
    }

    path "kv/data/iac/cloudflare" {
      capabilities = ["read"]
    }

    path "kv/data/iac/github-runner-pat" {
      capabilities = ["read"]
    }

    path "kv/data/iac/lxc-ssh" {
      capabilities = ["read"]
    }

    path "kv/data/iac/minio" {
      capabilities = ["read"]
    }

    path "kv/data/iac/minio-data-root" {
      capabilities = ["read"]
    }

    path "kv/data/iac/minio-root" {
      capabilities = ["read"]
    }

    path "kv/data/iac/proxmox" {
      capabilities = ["read"]
    }

    path "kv/data/services/authentik" {
      capabilities = ["read"]
    }

    path "kv/data/services/backup-health" {
      capabilities = ["read"]
    }

    path "kv/data/services/claude-247-pve" {
      capabilities = ["read"]
    }

    path "kv/data/services/cloudflare" {
      capabilities = ["read"]
    }

    path "kv/data/services/media/dashboard" {
      capabilities = ["read"]
    }

    path "kv/data/services/media/qbittorrent" {
      capabilities = ["read"]
    }

    path "kv/data/services/minio-obsidian" {
      capabilities = ["read"]
    }

    path "kv/data/services/palworld-panel" {
      capabilities = ["read"]
    }

    path "kv/data/services/pete-bot" {
      capabilities = ["read"]
    }

    path "kv/data/services/plane" {
      capabilities = ["read"]
    }

    path "kv/data/services/qbittorrent" {
      capabilities = ["read"]
    }

    path "kv/data/services/registry" {
      capabilities = ["read"]
    }

    path "kv/data/services/resume-builder" {
      capabilities = ["read"]
    }

    path "kv/data/services/search" {
      capabilities = ["read"]
    }

    path "kv/data/services/tailscale" {
      capabilities = ["read"]
    }

    path "kv/data/services/uptime-kuma" {
      capabilities = ["read"]
    }

    path "kv/data/services/vault-snapshots" {
      capabilities = ["read"]
    }

    path "kv/data/services/water-fast" {
      capabilities = ["read"]
    }
  EOT
}
