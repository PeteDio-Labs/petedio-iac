# Runbook — Vault resilience: audit device + raft snapshot backups (PET-109)

Vault (.223) is the platform root of trust (CI creds, DB passwords, Cloudflare tokens, SSH
keys). This runbook covers the three resilience gaps closed in PET-109 and the **operator
steps** to bring them up safely. The autonomous loop authored the code; **applying any of
this is operator-only** (it touches live Vault + MinIO).

What's in the repo now:
- **Audit device** — `vault-config/audit.tf` (`vault_audit` file device) + audit dir &
  logrotate in `ansible/playbooks/configure-vault.yml`.
- **Raft snapshot backups** — `vault-snapshot` policy + AppRole (`vault-config`), and the
  `vault-snapshot` Ansible role + `playbooks/vault-snapshot.yml` (timer → MinIO).

---

## ⚠️ Read first: the audit-device fail-closed footgun

Once **any** audit device is enabled, Vault is **fail-closed**: if it cannot write to a
configured audit device, it **stops serving requests** (returns 500s) until it can. So:

- The log path (`/opt/vault/logs`) **must exist and be writable by `vault`** *before* the
  `vault_audit` resource is applied — that's why `configure-vault.yml` runs first.
- Rotation must **reopen** the file (we send `SIGHUP` via logrotate `postrotate`), never
  rename/truncate it out from under Vault.
- Keep an eye on disk on .223 — a full disk on the audit volume will wedge Vault. (The
  log lives on the rootfs today; a single device is the homelab tradeoff.)

---

## Apply order (operator) — do NOT reorder

```sh
# 0. Pre-reqs: VAULT_ADDR/VAULT_CACERT/VAULT_TOKEN (root) in env for the vault-config apply
#    (see environments/homelab/vault-config/README.md), and AWS_* MinIO creds.

# 1. Host config first — creates /opt/vault/logs (vault-owned) + the logrotate config so the
#    audit path is writable BEFORE the device is enabled.
ansible-playbook ansible/playbooks/configure-vault.yml

# 2. Vault config — enables the audit device and creates the vault-snapshot policy + AppRole.
cd environments/homelab/vault-config && terraform init && terraform plan   # review!
terraform apply
cd -

# 3. MinIO target — create the bucket + a SCOPED svcacct (write to this bucket only), enable
#    versioning, and seed the creds into Vault (field names access_key/secret_key — the
#    snapshot script reads those). Bucket/svcacct creation is an mc admin op on .221.
mc mb   <minio-alias>/vault-snapshots
mc version enable <minio-alias>/vault-snapshots
# create a least-privilege svcacct restricted to the vault-snapshots bucket, then:
vault kv put kv/services/vault-snapshots access_key='<svcacct-key>' secret_key='<svcacct-secret>'

# 4. Seed the vault-snapshot AppRole creds on .223 (root-only, 0600). role_id is not secret;
#    secret_id is. Mint with the root token, then place under /etc/vault-snapshot/.
vault read  -field=role_id   auth/approle/role/vault-snapshot/role-id
vault write -f -field=secret_id auth/approle/role/vault-snapshot/secret-id
#   → on 223:  /etc/vault-snapshot/role_id   (0600 root)
#              /etc/vault-snapshot/secret_id (0600 root)

# 5. Install the timer.
ansible-playbook ansible/playbooks/vault-snapshot.yml
```

### Verify

```sh
vault audit list                                   # 'file/' present
systemctl list-timers vault-snapshot.timer         # scheduled
systemctl start vault-snapshot.service             # run once now
journalctl -u vault-snapshot.service -n 30         # "ok"; no secret in the log
mc ls <minio-alias>/vault-snapshots                # a vault-<ts>.snap object
```

---

## Restore from a snapshot

`vault operator raft snapshot restore` **overwrites the cluster's data** with the snapshot.
Do it deliberately, on an **unsealed** Vault, with the root token.

```sh
# Pull the desired snapshot back from MinIO.
mc cp <minio-alias>/vault-snapshots/vault-<ts>.snap /tmp/restore.snap

export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=/opt/vault/tls/vault.crt
export VAULT_TOKEN=<root token>

vault operator raft snapshot restore /tmp/restore.snap
```

> [!CAUTION]
> Restore replaces ALL current Vault data with the snapshot's. On a fresh/rebuilt 223:
> bring Vault up with `configure-vault.yml`, `vault operator init` a new cluster (or
> recover with the original unseal/recovery keys), unseal, then restore. The snapshot
> includes secrets + auth/policy config but NOT the unseal keys — keep those in the
> password manager. After a rebuild you re-seed the AppRole secret_id (step 4 above).

---

## Ergonomics (lower priority — notes only)

- **Manual unseal after every reboot of .223.** `configure-vault.yml` intentionally does not
  init/unseal; Vault comes up **sealed** on boot. After any 223 reboot, unseal with the keys
  from the password manager (`vault operator unseal` ×threshold). Acceptable for a homelab;
  auto-unseal (transit/cloud KMS) is out of scope here.
- **`vault-ca.crt` rotation breaks every consumer at once.** The listener cert is a 10-year
  self-signed CA committed at `environments/homelab/vault-ca.crt`; every client/CI job/the
  postgres provider verifies against it. When it rotates (regenerated by
  `configure-vault.yml` only if `/opt/vault/tls/vault.crt` is removed), **re-fetch and commit
  the new `vault-ca.crt` in the same change**, and expect all consumers to need the new CA
  simultaneously — coordinate it, don't do it piecemeal.
