# Audit device (PET-109). Vault is the platform root of trust (CI creds, DB passwords,
# Cloudflare tokens, SSH keys) but recorded nothing about who read/wrote which secret.
# A file audit device writes a hashed JSON line per request to the 223 host; rotation is
# handled by logrotate (configure-vault.yml) with SIGHUP so Vault reopens the file.
#
# ⚠️ TWO ORDERING/SAFETY RULES — see docs/runbooks/vault-resilience.md:
#   1. The file_path dir (/opt/vault/logs) must EXIST and be writable by the `vault` user
#      BEFORE this resource is applied — run configure-vault.yml first, or the enable fails.
#   2. Once any audit device is enabled, Vault is FAIL-CLOSED: if it cannot write to a
#      configured device it stops serving requests. Keep the disk healthy; rotation must
#      reopen (SIGHUP), never leave the path unwritable.
#
# log_raw defaults false, so secret values are HMAC-hashed in the log, not plaintext.
resource "vault_audit" "file" {
  type = "file"

  options = {
    file_path = "/opt/vault/logs/vault_audit.log"
  }
}
