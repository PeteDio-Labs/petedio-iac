# Runbook: Vault auto-unseal with AWS KMS

Vault on 223 unseals itself through one AWS KMS key. No unseal key sits on the Pi, the Mac agent or
223. This runbook covers the one-time migration from the Shamir seal, the restart proof, and the
retirement of the two watchers.

> I could not read HashiCorp's seal-migration page when I wrote this. The steps follow the
> documented `-migrate` flow for Vault 1.x. Check each result against the expected output below, and
> stop at the first difference.

## What changes

| Before | After |
|---|---|
| Shamir seal. Pi timer and Mac agent each hold the unseal key and race every 5 minutes. | `seal "awskms"` in `vault.hcl`. Vault opens itself on start. |
| Vault seals every night when the backup stops 223. | 223 leaves the nightly stop-backup (follow-up PR), so Vault restarts only on a real reboot. |
| Shamir shares unseal. | Shamir shares become **recovery keys**. They create a root token. They cannot unseal. |

The AWS user can encrypt, decrypt and describe one key, and only from the lab's public address.
`scripts/seed-vault-kms.sh` documents the policies.

## Known limits

- **A restart needs AWS and the internet.** With either missing, Vault stays sealed. Recovery keys
  cannot unseal.
- **A new public address blocks the seal.** Run `scripts/seed-vault-kms.sh --profile <profile> --update-ip`.
- **Disabling the KMS key stops Vault from unsealing.** That is also the emergency brake for a
  suspected compromise. A scheduled deletion destroys the data, so never delete the key.

- **The AWS account must outlive the credits.** The key costs about $1 a month after 2027-04-20.
  Closing or suspending the account stops Vault from unsealing.
- **The key policy does not deny `DisableKey` or `ScheduleKeyDeletion` to the account admin on
  purpose.** `DisableKey` is the emergency brake. The seal user cannot call either one, because its
  policy names three actions only.

## Steps

Run these from the Mac, in order, with the lab network reachable. Vault is unavailable for a few
minutes between steps 3 and 5.

1. **Create the key and the user.**
   `./scripts/seed-vault-kms.sh --profile <admin profile>`
   Expect `stored vault-seal-aws-key-id and vault-seal-aws-secret` and a key id.
2. **Confirm a fresh backup first.** Check that the newest object in the `vault-snapshots` bucket
   is under 24 hours old, or run `systemctl start vault-snapshot.service` on 223 and read its log.
   The migration rewrites how the root key is stored, so a snapshot is the way back.
   **Stop both watchers**, so neither sends a plain unseal during the migration.
   On the Pi: `sudo systemctl stop vault-unseal.timer`. On the Mac: `pet-secrets watch uninstall`.
3. **Write the migration config.**
   `./scripts/deploy-vault-seal.sh --key-id <key id> --migrating`
   Expect the play to restart Vault, and `vault status` to show `Sealed true`.
4. **Migrate.** Send the existing unseal key with `migrate` set. Read it from the Keychain, never
   from argv:
   ```bash
   security find-generic-password -s vault-unseal-key -w \
     | python3 -c 'import json,sys;print(json.dumps({"key":sys.stdin.read().strip(),"migrate":True}))' \
     | curl -sS --cacert environments/homelab/vault-ca.crt --request PUT --data @- \
         https://192.168.50.223:8200/v1/sys/unseal
   ```
   Expect `"sealed":false` and `"migration":false` in the answer, and then:
   `vault status` reports `Seal Type awskms` and `Recovery Seal Type shamir`.
5. **Remove the disabled Shamir block.**
   `./scripts/deploy-vault-seal.sh --key-id <key id>`
6. **Prove the restart.** On 223 run `systemctl restart vault`. Within about 30 seconds
   `curl --cacert environments/homelab/vault-ca.crt https://192.168.50.223:8200/v1/sys/seal-status`
   must show `"sealed":false` with no watcher running. If it stays sealed, read `journalctl -u vault`
   on 223. A KMS denial names the address AWS saw.
7. **Retire the watchers.** Disable the Pi timer and delete `/etc/vault-unseal/unseal-key` on the
   Pi. Keep the Keychain items `vault-unseal-key` and `vault-root-token`: the unseal key is now a
   recovery key.
8. **Confirm the alert.** Stop Vault for 11 minutes in a test, or read the `vault` monitor
   settings, and confirm Uptime Kuma marks a sealed Vault as down. A sealed Vault answers
   `/v1/sys/health` with 503.

Follow-up PRs: put 223 in `backup_store_jobs[].exclude`, and remove the `vault-unseal` role.

## Roll back

Before step 5, remove `vault_awskms_key_id` from the extra-vars and rerun `configure-vault.yml`.
After the migration finishes, moving back to Shamir is another `-migrate` run, and it needs KMS
reachable.
