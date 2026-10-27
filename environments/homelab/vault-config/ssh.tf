# SSH certificate authority (PET-771): per-role SSH access, signed by Vault.
#
# WHY. Every CD role shared one key, kv/iac/lxc-ssh, which opens root on every Terraform LXC,
# 247, Vault 223 and runner 232 (audit H6). Pedro chose Vault-signed certificates on 2026-10-27
# over FreeIPA, an authentik LDAP outpost and per-role static keys.
#
# HOW IT WORKS. A caller sends its public key to ssh-client-signer/sign/<role>. Vault returns a
# certificate that names one or more principals and expires after the role's TTL. A host trusts
# the CA through TrustedUserCAKeys and lists, per local user, which principals may log in as
# that user (roles/ssh-ca). A host verifies a certificate offline, so no host calls Vault.
#
# WHAT IT DOES NOT DO. Revocation is by short TTL, not a revocation list. Vault seals nightly, so
# nothing is signed while it is sealed: a scheduled caller fails loudly on a sealed Vault.
#
# The CA private key is generated inside Vault and never leaves it. The state holds only the
# public key.

resource "vault_mount" "ssh_client_signer" {
  path        = "ssh-client-signer"
  type        = "ssh"
  description = "SSH user certificate authority, one signing role per identity (PET-771)."

  # Bounds every role's TTL below. No role here needs more than Pedro's 8 hours.
  max_lease_ttl_seconds = 28800
}

resource "vault_ssh_secret_backend_ca" "client_signer" {
  backend              = vault_mount.ssh_client_signer.path
  generate_signing_key = true
  key_type             = "ssh-ed25519"
}

# inventory-read: the PET-770 CVE collector on 237. It logs in as the non-root user
# `inventory`, which has no sudo, and reads package and version lists. The source-address
# critical option makes a leaked certificate useless from anywhere but 237. No pty, no
# forwarding: the collector runs commands, it never opens a shell.
resource "vault_ssh_secret_backend_role" "inventory_read" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "inventory-read"
  key_type = "ca"

  allow_user_certificates = true
  allowed_users           = "inventory-read"
  default_user            = "inventory-read"
  allow_user_key_ids      = false

  allowed_extensions = ""
  default_extensions = {}

  allowed_critical_options = "source-address"
  default_critical_options = {
    "source-address" = "192.168.50.237/32"
  }

  ttl     = "1800"
  max_ttl = "1800"

  allowed_user_key_config {
    type    = "ed25519"
    lengths = [0]
  }
}

# pedro: Pedro's own key (Termius on the phone, or the Mac), root on every host that lists the
# principal. Signed only from the break-glass token (breakglass.tf), so a root certificate
# needs Pedro's password and TOTP, the way root SSH already does since PET-725.
resource "vault_ssh_secret_backend_role" "pedro" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "pedro"
  key_type = "ca"

  allow_user_certificates = true
  allowed_users           = "pedro"
  default_user            = "pedro"
  allow_user_key_ids      = false

  allowed_extensions = "permit-pty"
  default_extensions = {
    "permit-pty" = ""
  }

  ttl     = "28800"
  max_ttl = "28800"

  allowed_user_key_config {
    type    = "ed25519"
    lengths = [0]
  }
}

# Signs one role and reads nothing else. Attach it to the login that a role's caller uses. The
# collector's AppRole on 237 lands with PET-770, bound to 237's /32 like ansible-247.
resource "vault_policy" "ssh_sign_inventory_read" {
  name = "ssh-sign-inventory-read"

  policy = <<-EOT
    path "${vault_mount.ssh_client_signer.path}/sign/${vault_ssh_secret_backend_role.inventory_read.name}" {
      capabilities = ["update"]
    }
  EOT
}

output "ssh_ca_public_key" {
  description = "The CA public key roles/ssh-ca installs. Hosts read it from Vault, not from here."
  value       = vault_ssh_secret_backend_ca.client_signer.public_key
}
