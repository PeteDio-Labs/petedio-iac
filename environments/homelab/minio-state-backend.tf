# minio-state-backend.tf — intentionally NO resources. (PET-124)
#
# The MinIO host that backs Terraform state (LXC 221 / 192.168.50.221, bucket
# `tfstate`; see backend.tf) is HAND-MANAGED BY DESIGN and has NO Terraform resource —
# not here, not anywhere, ever.
#
# Why it can't be in Terraform (bootstrap circularity):
#   Creating .221 as a `proxmox_virtual_environment_container` would require a
#   `terraform apply` whose OWN state lives in the `tfstate` bucket ON .221. You cannot
#   bootstrap the state store from the resource that depends on it — a destroy/recreate
#   of .221 in a plan would mean deleting the bucket Terraform is mid-read/write against.
#   So .221 is the one deliberate exception to "everything is Terraform".
#
# Decision record: the MinIO ADR (PET-102) — "MinIO .221 TF state backend stays
# hand-managed by design".
#
# How .221 IS kept as code instead:
#   - Config-as-code .... ansible/roles/minio + ansible/playbooks/configure-minio.yml
#   - Disaster recovery .. docs/runbooks/minio-221-rebuild.md (bare LXC -> Ansible ->
#                          restore tfstate from backup -> terraform init)
#   - Backend wiring ..... backend.tf (the S3 backend that consumes this host)
#   - tfstate svcacct .... scripts/reseed-minio-vault.sh (-> Vault kv/iac/minio)
#
# This file exists so the absence of a .221 resource is self-documenting: if you came
# here looking for "where's the MinIO container?", this is the answer — it's on purpose.
