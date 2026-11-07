# Feature gates for the homelab workspace (PET-884). Terraform loads this file on its own, so
# CI and a local plan read the same values. To change a gate, edit this file in a pull request.
# This replaces the repository variables MANAGE_RESOURCE_POOL, MANAGE_BACKUP_JOB,
# EMAIL_ROUTING_LIVE and EMAIL_ROUTING_FORWARD, which needed a hand step in the GitHub settings.
# The values below match those variables at 2026-11-07 (read with the repo_vars action).
#
# A gate turns on only after its prerequisite is met; the variable's description in
# variables.tf names it.
manage_resource_pool   = true
manage_backup_job      = false
email_routing_live     = true
email_routing_forward  = true
