# admin DB — the co-latro-admin service's own logical DB on postgres-rds-231 (PET-88).
# The co-latro-admin service connects as the `admin` role.
#
# The database, its owner role and its grant are now declared in databases.tf along with
# every other Postgres database. This file previously held a near-identical copy of the
# ephemeral Vault read, the password-resolution locals and the module block; that triple was
# duplicated once per database until it was consolidated into a single for_each map.
#
# Secret: kv/admin/db { owner_password } — seeded by scripts/reseed-admin-db-vault.sh, with
# ci-read/terraform granted read on kv/data/admin/* (vault-config/policies.tf) so CI can
# resolve it at plan time. The map entry in databases.tf records that path and field name.
#
# Kept as a file rather than deleted: the `admin` DB has its own Linear history and its own
# Vault path, and a reader looking for "where is the admin database defined" should land
# somewhere that says so.
