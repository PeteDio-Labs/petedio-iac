# Secrets register

`secrets/register.yml` lists every Vault path the code reads. It records an owner, a rotation
method and an expiry rule for each, and it holds no values (`PET-685`).

## What checks it

| Check | Where it runs | Fails when |
|---|---|---|
| `offline` job | every pull request, GitHub-hosted | code reads a `kv/...` path with no register entry, or an entry has no reader and no `consumers_external` |
| `nightly` job | 06:17 UTC on the homelab runner | the offline failures, plus a path absent from Vault, or an expiry within 21 days |

The nightly job mints the `secrets-register` Vault role. That role reads KV metadata (path
names, versions and timestamps) and one secret, `kv/services/secrets-register`. It DMs Pedro
through pete-bot when it fails. The last line of every run says what it examined, and a run
below 10 entries or 40 files fails.

## Add a secret

1. Add an entry to `secrets/register.yml` in the same pull request that adds the code.
2. Name the script that seeds or rotates it in `rotation`. Write `unrecorded: <why>` when none exists.
3. Set `expiry` to `{rule: none}`, `{rule: ttl_days, days: N}` (counted from the path's last write)
   or `{rule: date, date: YYYY-MM-DD}`.

A path that code reads through a template, such as `kv/services/plane-$name`, matches an entry
with a glob: `kv/services/plane-*`. `optional: true` lets a path be absent from Vault.
`status: retired` waives the reader and absence checks for a path kept for history.
`kind: external` records a credential that is not a KV path, such as a Vault token.

## Run it by hand

```bash
python3 scripts/secrets-register.py --self-test   # an entry that expires in 7 days must fail
python3 scripts/secrets-register.py               # register against code
VAULT_ADDR=https://192.168.50.223:8200 VAULT_CACERT=environments/homelab/vault-ca.crt \
  VAULT_TOKEN=... python3 scripts/secrets-register.py --live
```

## Set up the nightly job

1. Run `scripts/apply-vault-config.sh` to create the `secrets-register` role and policy.
2. Run `scripts/seed-secrets-register.sh` to copy pete-bot's notify token.
3. Run the `secrets-register` workflow once with `workflow_dispatch`.

## Known gaps

- The checker finds reads by text. A path built at run time without a literal prefix is invisible to it.
- Entries marked `unrecorded` have no seed script. Each is a rotation nobody can repeat.
- AppRole `secret_id` expiry (`PET-687`) is not in the register yet, because a `secret_id`
  is not a KV path and the Mac holds no record of its mint date.
