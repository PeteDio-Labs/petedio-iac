# Vault web sign-in through Authentik (PET-946)

Vault's page is at `vault.pdlab.dev`. Two gates stand in front of it: Cloudflare Access (Authentik login and Pedro's email), then Vault's own OIDC method, which also signs in through Authentik. The root token stays the break-glass login.

## What a sign-in can do

The `pedro` OIDC role grants the `keys-list` policy (`vault-config/keys.tf`). That policy lists and reads metadata under `kv/callers/edge`: agent names, versions and owners. It reads no secret value and no other path. To widen it, change `keys.tf` in its own PR.

## Set up

1. In the Authentik dashboard, create the provider and application by hand: slug `vault`, confidential client, implicit consent, scopes `openid email profile`, and the redirect URIs listed in `scripts/seed-vault-oidc.sh`. Check `https://auth.pdlab.dev/application/o/vault/.well-known/openid-configuration`.
2. Merge the PR. The apply-on-merge job creates the route.
3. On the Mac, run `scripts/apply-vault-config.sh` to mount `auth/oidc` and create the `pedro` role.
4. On the Mac, run `scripts/seed-vault-oidc.sh`. It writes `auth/oidc/config` from the client id and secret and prints no secret.
5. Sign in at `vault.pdlab.dev` with method OIDC, or run `vault login -method=oidc role=pedro`.

## If it breaks

- A sealed Vault shows no sign-in. It unseals itself through AWS KMS: see `vault-kms-seal.md`.
- If Authentik is down, use the root token, which stays valid. The Cloudflare Access gate also depends on Authentik, so use the LAN address then.
- To turn the page off, remove the `vault.pdlab.dev` route and merge.
