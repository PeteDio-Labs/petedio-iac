# Break-glass Vault admin, unlocked from Pedro's phone on 247 (PET-714).
#
# Pedro's decision (2026-10-20): after the $20-plan cutover, 247 keeps its standing
# day-to-day access, and Vault admin is unlocked by hand for one hour at a time. The Mac's last
# Vault jobs (the seed scripts, scripts/apply-vault-config.sh) move to 247 that way, without a
# standing admin token on a host that runs Claude sessions in auto mode.
#
# HOW AN UNLOCK WORKS. Pedro SSHes to 247 from his phone as `pedro` (PET-713), a user that runs
# no Claude session, and runs /usr/local/bin/vault-breakglass. It logs in on the userpass mount
# below with his password, Vault asks for a TOTP code (the enforcement below), and the token
# lives only in that shell's environment: never on disk, and unreadable to claude-ops, which is
# another UID with no sudo.
#
# ⚠ WHAT THIS POLICY IS. A token that can write policies and auth roles is root-equivalent for
# its lifetime: it can grant itself anything. The explicit denies below stop an accidental read
# of kv/admin/*, not a determined one. The containment is who can mint it (Pedro's password and
# his phone's TOTP), where it works (token_bound_cidrs, set by the seed script to 247's /32),
# and for how long (one hour, not renewable). The root token and the unseal keys still never
# land on 247.
#
# The user, its password and its TOTP secret are NOT here: a password in this config would sit
# in the state file. scripts/seed-breakglass-247.sh creates them once, from the Mac, with the
# root token. Apply this file first; the seed script refuses to run until the mount, the policy
# and the enforcement exist.

resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = "userpass"
  description = "Pedro's break-glass login from 247, TOTP-enforced (PET-714)"
}

resource "vault_policy" "breakglass_247" {
  name = "breakglass-247"

  policy = <<-EOT
    # What scripts/apply-vault-config.sh changes: policies, auth methods and their roles,
    # mounts, the audit device and identity.
    path "sys/policy" {
      capabilities = ["read", "list"]
    }
    path "sys/policy/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl" {
      capabilities = ["list"]
    }
    path "sys/policies/acl/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/auth" {
      capabilities = ["read"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "auth/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/audit" {
      capabilities = ["read", "sudo"]
    }
    path "sys/audit/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "identity/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/leases/*" {
      capabilities = ["read", "update", "list"]
    }

    # What the seed scripts do: write and read named secrets.
    path "kv/data/*" {
      capabilities = ["create", "read", "update", "patch", "delete"]
    }
    path "kv/metadata/*" {
      capabilities = ["read", "list", "delete"]
    }

    # Never, even here: the prefix that documents the root token and the unseal material
    # (PET-702), and the operations that mint a root token or change the seal.
    path "kv/data/admin/*" {
      capabilities = ["deny"]
    }
    path "kv/metadata/admin/*" {
      capabilities = ["deny"]
    }
    path "sys/generate-root*" {
      capabilities = ["deny"]
    }
    path "sys/rekey*" {
      capabilities = ["deny"]
    }
    path "sys/rotate*" {
      capabilities = ["deny"]
    }
    path "sys/seal" {
      capabilities = ["deny"]
    }
  EOT
}

resource "vault_identity_mfa_totp" "breakglass" {
  issuer    = "PeteDio Vault"
  period    = 30
  digits    = 6
  algorithm = "SHA1" # what phone authenticator apps all read
  key_size  = 20
  # Rate-limits a guessed code: Vault locks the method after this many bad codes until the
  # period passes.
  max_validation_attempts = 5
}

# Every login on the userpass mount needs a TOTP code. Pedro's is the only user on it.
resource "vault_identity_mfa_login_enforcement" "breakglass" {
  name                  = "breakglass-247"
  mfa_method_ids        = [vault_identity_mfa_totp.breakglass.method_id]
  auth_method_accessors = [vault_auth_backend.userpass.accessor]
}

output "breakglass_totp_method_id" {
  description = "The TOTP method scripts/seed-breakglass-247.sh enrols Pedro's entity on."
  value       = vault_identity_mfa_totp.breakglass.method_id
}
