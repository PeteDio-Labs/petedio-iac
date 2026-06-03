# KV v2 secrets engine — the single store for app + infra secrets. Logical
# layout under kv/: iac/* (proxmox, minio, lxc-ssh, ...), poker/*, services/*.
# KV v2 means reads/writes go through kv/data/<path> and listing/metadata through
# kv/metadata/<path> — the policies in policies.tf are written against those.
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv-v2"
  description = "App + infra secrets (KV v2)."
}
