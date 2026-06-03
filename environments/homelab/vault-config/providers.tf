# Vault provider — config-only workspace for the running Vault on LXC 223 (.223).
#
# Auth is supplied entirely by ENV the operator sets out-of-band; NONE of it is
# committed and NONE of it enters public CI. This workspace is applied MANUALLY:
#
#   export VAULT_ADDR=https://192.168.50.223:8200
#   export VAULT_CACERT=../vault-ca.crt              # self-signed homelab CA
#   export VAULT_TOKEN=<root/bootstrap token from the password manager>
#
# The homelab Vault uses a self-signed cert (matches the insecure Proxmox/MinIO
# LAN posture), so VAULT_CACERT must point at its CA bundle to verify TLS rather
# than disabling verification. This file is NOT wired into terraform.yml — the
# repo CI only cd's into environments/homelab, so this dir is naturally excluded.
provider "vault" {}
