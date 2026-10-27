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

  # Bounds every role's TTL below. No role here needs more than Pedro's hour.
  max_lease_ttl_seconds = 3600

  # Vault holds the only copy of the CA private key. Destroying the mount destroys the key, and
  # every host would have to trust a new one. To retire the CA on purpose, remove both
  # lifecycle blocks in a reviewed PR first; scripts/apply-vault-config.sh --allow-destroy
  # cannot override prevent_destroy.
  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_ssh_secret_backend_ca" "client_signer" {
  backend              = vault_mount.ssh_client_signer.path
  generate_signing_key = true
  key_type             = "ssh-ed25519"

  # The break-glass token applies this file, and its policy gains config/* and roles/* in the
  # same apply. Vault reads a policy on every request, so the grant counts once it is written.
  depends_on = [vault_policy.breakglass_247]

  lifecycle {
    prevent_destroy = true
  }
}

# inventory-read: the PET-770 CVE collector on 237. It logs in as the non-root user
# `inventory`, which has no sudo, and reads package and version lists. The source-address
# critical option makes a leaked certificate useless from anywhere but 237. No pty, no
# forwarding: the collector runs commands, it never opens a shell.
resource "vault_ssh_secret_backend_role" "inventory_read" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "inventory-read"
  key_type = "ca"

  depends_on = [vault_policy.breakglass_247]

  allow_user_certificates = true
  allowed_users           = "inventory-read"
  default_user            = "inventory-read"
  allow_user_key_ids      = false

  allowed_extensions = ""
  default_extensions = {}

  # ⚠ NOT EMPTY, AND NOT "source-address". Vault reads an empty list as "any option", and a
  # request that names any critical option replaces the defaults below instead of adding to
  # them (calculateCriticalOptions in builtin/logical/ssh/path_issue_sign.go). So a signer
  # could drop the /32 either way. This list names one option that does not exist: a request
  # for source-address is refused, and a request for this name gives a certificate that sshd
  # refuses, because sshd rejects an unknown critical option.
  allowed_critical_options = "petedio-no-overrides"
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
#
# One hour, the break-glass token's own life. source-address is the LAN and the tailnet's CGNAT
# range, not one host: the phone arrives through the pete-pi-1 subnet router, which rewrites its
# address to the router's LAN address, and the Mac or 247 arrive from the LAN. A lifted
# certificate is then root only from inside the LAN or the tailnet, for at most an hour.
resource "vault_ssh_secret_backend_role" "pedro" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "pedro"
  key_type = "ca"

  depends_on = [vault_policy.breakglass_247]

  allow_user_certificates = true
  allowed_users           = "pedro"
  default_user            = "pedro"
  allow_user_key_ids      = false

  allowed_extensions = "permit-pty"
  default_extensions = {
    "permit-pty" = ""
  }

  # The same sentinel as inventory-read, for the same reason: no request can drop the default.
  allowed_critical_options = "petedio-no-overrides"
  default_critical_options = {
    "source-address" = "192.168.50.0/24,100.64.0.0/10"
  }

  ttl     = "3600"
  max_ttl = "3600"

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
