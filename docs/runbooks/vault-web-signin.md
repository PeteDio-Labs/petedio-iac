# Vault sign-in through Authentik (PET-946)

Vault's OIDC method signs in through Authentik. The root token stays the break-glass login. Today you reach the page on the Lab address, `https://192.168.50.223:8200`. A `vault.pdlab.dev` route behind Cloudflare Access is held until the tunnel can verify Vault's certificate: the tunnel runs in Docker on LXC 112, which needs Vault's CA mounted first. The Vault callback for that host is already in the role's allowed redirect URIs.

## What a sign-in can do

The `pedro` OIDC role grants the `keys-list` policy (`vault-config/keys.tf`). That policy lists and reads metadata under `kv/callers/edge`: agent names, versions and owners. It reads no secret value and no other path. To widen it, change `keys.tf` in its own PR.

## Set up

1. Merge the PR.
2. On the Mac, run `scripts/apply-vault-config.sh` to mount `auth/oidc` and create the `pedro` role.
3. On the Mac, run `scripts/seed-vault-oidc.sh`. It creates the Authentik `vault` provider and application through the API, with the bootstrap token from `kv/services/authentik`, then writes `auth/oidc/config` from the client it reads back. It prints no secret and creates nothing if the application exists. If the bootstrap token no longer works, make the app by hand (slug `vault`, confidential, implicit consent, scopes `openid email profile`, the redirect URIs in the script) and pass `VAULT_OIDC_CLIENT_ID` and `VAULT_OIDC_CLIENT_SECRET`.
4. Sign in at `https://192.168.50.223:8200` with method OIDC, or run `vault login -method=oidc role=pedro`.

## If it breaks

- A sealed Vault shows no sign-in. It unseals itself through AWS KMS: see `vault-kms-seal.md`.
- If Authentik is down, use the root token, which stays valid.
