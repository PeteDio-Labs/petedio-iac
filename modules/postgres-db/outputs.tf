output "db_name" {
  description = "Name of the created database."
  value       = postgresql_database.this.name
}

output "owner_role" {
  description = "Name of the owning login role."
  value       = postgresql_role.owner.name
}
