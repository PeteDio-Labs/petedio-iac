# Runbook: Vault auto-unseal with AWS KMS

Vault on 223 unseals itself through one AWS KMS key. No unseal key sits on the Pi, the Mac agent or
223. This runbook covers the one-time migration from the Shamir seal, the restart proof, and the
retirement of the two watchers.

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

The 2026-11-18 migration ran these steps from the Mac, with the lab network reachable. Vault is
unavailable for a few seconds at step 3.

1. **Create the key and the user.**
   `./scripts/seed-vault-kms.sh --profile <admin profile>`
   Expect `stored vault-seal-aws-key-id and vault-seal-aws-secret` and a key id. The script waits
   for AWS to register the new user: it retries the key policy up to 6 times, 10 seconds apart.
2. **Confirm a fresh backup.** Check that the newest object in the `vault-snapshots` bucket is
   under 24 hours old, or run `systemctl start vault-snapshot.service` on 223 and read its log.
   The migration rewrites how the root key is stored, so a snapshot is the way back.
3. **Write the KMS seal config.**
   `./scripts/deploy-vault-seal.sh --key-id <key id>`
   Expect the play to restart Vault, and `/v1/sys/seal-status` to show
   `"type":"awskms","sealed":true,"migration":true`. Do not add a `seal "shamir"` block: Vault 2.0.1
   refuses `disabled = "true"`.
4. **Migrate.** Send the existing unseal key with `migrate` set. Read it from the Keychain, never
   from argv:
   ```bash
   security find-generic-password -s vault-unseal-key -w \
     | python3 -c 'import json,sys;print(json.dumps({"key":sys.stdin.read().strip(),"migrate":True}))' \
     | curl -sS --cacert environments/homelab/vault-ca.crt --request PUT --data @- \
         https://192.168.50.223:8200/v1/sys/unseal
   ```
   Expect `"sealed":false`. Then `vault status` reports `Seal Type awskms` and
   `Recovery Seal Type shamir`.
5. **Rerun the deploy.** `./scripts/deploy-vault-seal.sh --key-id <key id>` must report
   `changed=0`, and `seal-status` must show `"migration":false`.
6. **Retire the watchers.** On the Mac, `pet-secrets watch uninstall`. On the Pi, run
   `cd ansible && ansible-playbook playbooks/configure-vault-unseal.yml`. It stops the timer and
   removes the unit, the script and the log. It leaves `/etc/vault-unseal/unseal-key` and the
   Keychain items `vault-unseal-key` and `vault-root-token`: the unseal key is now a recovery key,
   and these are its two copies.
7. **Prove the restart.** On 223 run `systemctl restart vault`. Within about 10 seconds
   `curl --cacert environments/homelab/vault-ca.crt https://192.168.50.223:8200/v1/sys/seal-status`
   must show `"sealed":false` with no watcher running. If it stays sealed, read `journalctl -u vault`
   on 223. A KMS denial names the address AWS saw.
8. **Confirm the alert.** A sealed Vault answers `/v1/sys/health` with 503, so the Uptime Kuma
   `vault` monitor goes down. Check its settings once.

The nightly stop-backup no longer includes 223 (`backup_store_jobs[].exclude`).

## Roll back

Before step 4, rerun `configure-vault.yml` without the key id and unseal with the Shamir key.
After the migration finishes, moving back to Shamir is another migrate run, and it needs KMS
reachable.
