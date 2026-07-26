# Every logical Postgres database on postgres-rds-231, in one place.
#
# WHY THIS FILE EXISTS. Each database used to carry its own ephemeral Vault read, its own
# `locals` block resolving TF_VAR-then-Vault, its own module block, and two or three root
# variables — spread across postgres.tf, admin.tf, waterfast.tf and variables.tf, plus a
# per-secret grant in the separate vault-config root. Roughly 100 lines and six files to add
# one database, and the `ci-read` grant was easy to forget because it lives in a root that
# apply-on-merge never runs. Adding `waterfast` is what made the cost obvious.
#
# Now: one map entry, plus seeding the secret in Vault.
#
# WHAT IS *NOT* HERE. The Postgres **host** (LXC 231) stays in postgres.tf, and the
# credential the postgresql *provider* connects with stays there too — that's a property of
# the server, not of any one database. This file owns only the logical layer, which is the
# same split modules/postgres-db draws (RDS instance vs. the databases inside it).

locals {
  # One entry per database. `vault_path` and `password_field` are per-entry because the
  # three live secrets were seeded under three different conventions, before there was one:
  #
  #   poker      kv/poker/db            field poker_password
  #   admin      kv/admin/db            field owner_password
  #   waterfast  kv/services/water-fast field db_password
  #
  # Migrating live secrets as part of an already-delicate refactor would mean rewriting
  # paths, policies and consumers in the same change as moving state — so the map absorbs
  # the inconsistency instead. NEW databases should omit both fields and take the defaults
  # below (kv/db/<name>, field `password`), which is the convention to converge on; the
  # three legacy entries can be migrated later as their own, separately-reviewable change.
  postgres_databases = {
    poker = {
      vault_path     = "poker/db"
      password_field = "poker_password"
    }
    admin = {
      vault_path     = "admin/db"
      password_field = "owner_password"
    }
    waterfast = {
      vault_path     = "services/water-fast"
      password_field = "db_password"
    }
  }

  # Defaults applied to every entry, so a new database needs only `name = {}`.
  postgres_databases_resolved = {
    for name, cfg in local.postgres_databases : name => {
      vault_path     = try(cfg.vault_path, "db/${name}")
      password_field = try(cfg.password_field, "password")
    }
  }

  # var.postgres_ready is the same two-phase gate the host has always used: false means
  # Postgres isn't reachable yet, so neither the provider nor Vault is contacted. Ephemeral
  # resources are opened at PLAN time, so gating the read matters as much as gating the
  # module — an ungated read of an absent path fails the plan, not just the apply.
  postgres_databases_active = var.postgres_ready ? local.postgres_databases_resolved : {}
}

ephemeral "vault_kv_secret_v2" "postgres_db" {
  for_each = local.postgres_databases_active

  mount = "kv"
  name  = each.value.vault_path
}

module "postgres_db" {
  source   = "../../modules/postgres-db"
  for_each = local.postgres_databases_active

  db_name    = each.key
  owner_role = each.key

  # Ephemeral all the way through: the Vault read is ephemeral, owner_password is declared
  # ephemeral in the module, and it feeds postgresql_role.password_wo — so the password
  # lands in neither the plan nor the state (PET-107 / PET-190).
  owner_password = try(
    var.postgres_db_passwords[each.key],
    ephemeral.vault_kv_secret_v2.postgres_db[each.key].data[each.value.password_field],
  )

  # A write-only password is invisible to the diff, so this integer is what actually
  # triggers re-application. Bump an entry after reseeding Vault to push the new value
  # through; unlisted databases default to 1.
  owner_password_version = try(var.postgres_db_password_versions[each.key], 1)
}

# ---- state moves --------------------------------------------------------------------------
#
# poker and admin are LIVE and already in state at their old addresses. Without these,
# Terraform would plan to destroy the old module instances and create new ones — against
# `postgresql_database`, whose identity IS the database name, that reads as dropping and
# recreating a database with real data in it.
#
# The gate on this refactor is a plan showing **0 destroyed**. Anything else is a
# STOP-and-reassess (docs/runbooks/postgres-import.md).
moved {
  from = module.poker_db[0]
  to   = module.postgres_db["poker"]
}

moved {
  from = module.admin_db[0]
  to   = module.postgres_db["admin"]
}

# ---- adopting the live `waterfast` objects ------------------------------------------------
#
# waterfast was created by hand alongside the first deploy (same as poker originally was),
# so it exists on the server but has never been in state. Import writes the live objects
# into state so the following plan is a diff against reality rather than a create-from-
# nothing, which against a live host errors "already exists" at best.
#
# The GRANT is deliberately absent: postgresql_grant defines no Importer at provider v1.x,
# so it cannot be imported. Its Create is idempotent on the database (the role already holds
# ALL), so apply adds the state entry and does nothing to Postgres — the provider-supported
# path, and the same one poker took. Expect exactly one resource to add for this reason.
import {
  to = module.postgres_db["waterfast"].postgresql_role.owner
  id = "waterfast"
}

import {
  to = module.postgres_db["waterfast"].postgresql_database.this
  id = "waterfast"
}
