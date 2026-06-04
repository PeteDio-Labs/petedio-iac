# GOTCHAS — hard-won patterns for this stack

Carry-forward lessons. Every story that hits a new one appends here (Definition of Done).

## Proxmox / bpg

- **bpg import never round-trips** `operating_system.template_file_id`, `features`,
  `initialization.user_account`. Always `lifecycle { ignore_changes = [...] }` them,
  or every plan shows phantom drift.

- **Proxmox API tokens can't set LXC `features{}`.** The API enforces a hardcoded
  `user == root@pam` check for features other than bare `nesting`; an API token's
  username is `root@pam!tokenid`, not `root@pam`, so it fails — even for a PVEAdmin
  token. **Workaround:** TF creates the LXC *without* a `features{}` block; Ansible
  (or `pct set <id> --features nesting=1,keyctl=1` over ssh-as-root) sets them
  out-of-band. Keep `features` in `ignore_changes`.

- **Target the correct node endpoint.** bpg reads the PVE version from the endpoint
  and version-gates fields. Cluster nodes can differ (pve01 9.1.x). Point
  `proxmox_endpoint` at the node where the resources live.

- **On pve01 the LAN/uplink bridge is `vmbr1`, NOT `vmbr0`.** `vmbr0` = `eno1`, a
  separate segment with no gateway — a container on it has an IP but cannot ARP the
  gateway (outbound 100% loss, DNS fails). `vmbr1` = `eno2`/`eno3`, where the
  working containers live. **Do NOT copy net config from a pve02 container** (the old
  MinIO/115 uses `vmbr0` *on pve02*, where the bridge layout differs). Discovered
  2026-06-02 standing up the fresh MinIO (.221).

## MinIO S3 state backend

- Needs `use_path_style = true` + all four `skip_*` flags
  (`skip_credentials_validation`, `skip_region_validation`, `skip_metadata_api_check`,
  `skip_requesting_account_id`). `region` is required by Terraform but ignored by MinIO.
- **No locking** (MinIO doesn't speak DynamoDB). Single operator; never run concurrent
  applies (local + CI). **Bucket versioning is the safety net** — enable it
  (`mc version enable <alias>/<bucket>`) so a corrupt state can roll back.
- Creds come from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (env locally, Actions
  secrets in CI). Never inline in `backend.tf`.

## CI / runner

- The runner must live **inside** the homelab — a GitHub-hosted runner cannot route to
  `192.168.50.0/24` (Proxmox API + MinIO). `runs-on: [self-hosted, linux, x64, homelab]`.
- **Chicken-and-egg:** the runner is declared in `runner.tf`, but the first CI run needs
  a runner that doesn't exist yet. Break it by applying the runner LOCALLY once
  (`terraform apply -target=...container.runner`) + Ansible-registering it, then let CI
  take over.

## Vault — TLS + GitHub-OIDC (PET-29)

- **Self-signed CA, so verify — don't skip.** Vault on .223 serves an HTTPS listener
  with a self-signed CA (matches the LAN's insecure Proxmox/MinIO posture). The CA is
  committed at `environments/homelab/vault-ca.crt`. Verify against it
  (`VAULT_CACERT=…/vault-ca.crt` locally; vault-action's `caCertificate` in CI) — never
  `tlsSkipVerify`/`-tls-skip-verify`. A leaf-cert SAN must cover the address you dial
  (this cert lists `192.168.50.223` + `vault.local`); dialing a name not in the SAN
  fails TLS even with the right CA.

- **`vault-action`'s `caCertificate` wants BASE64-encoded PEM, not raw PEM or a path.**
  A workflow `with:` value can't read a file, so add a preceding step that base64s the
  committed CA into a step output and pass that:
  `echo "b64=$(base64 -w0 vault-ca.crt)" >> "$GITHUB_OUTPUT"` →
  `caCertificate: ${{ steps.<id>.outputs.b64 }}`. The path is relative to the job's
  `working-directory` (CI `cd`s into `environments/homelab`, where the cert lives).

- **GitHub OIDC `sub` differs by event — bind BOTH or you break plan-on-PR.**
  push-to-main → `repo:<owner>/<repo>:ref:refs/heads/main`; pull_request →
  `repo:<owner>/<repo>:pull_request`. CI's plan (PR) and apply (merge) BOTH run
  terraform → both need creds → both subs must be allowed. Bind exactly those two,
  not repository-only (any branch/workflow) and not main-only (kills PR plans).

- **The Terraform provider only takes STRING `bound_claims`, not lists.** Put multiple
  allowed values in ONE comma-separated string with OR semantics:
  `bound_claims = { sub = "<main-sub>,<pr-sub>" }`, and set
  `bound_claims_type = "string"` (exact match) — `glob` is only for wildcards.

- **`jwtGithubAudience` MUST equal the role's `bound_audiences`.** We use
  `https://github.com/PeteDio-Labs` (`var.github_oidc_audience`). A mismatch → Vault
  rejects the login with an audience error, not an obvious one.

- **Public repo + self-hosted runner = a real exposure (follow-up).** Fork
  `pull_request`s can run on a self-hosted runner that can reach Vault. The `sub`
  binding scopes WHICH OIDC tokens are accepted, but doesn't stop untrusted PR code
  from running on the runner. Gate fork PRs (require-approval / trusted-only) before
  relying on this in anger.

## App rollout — Co-latro / poker-api 230 (PET-12/43/44)

- **The `ansible` Vault policy can't read `kv/poker/*` — by design.** Least-privilege:
  Ansible host-config reads `kv/iac/*` + `kv/services/*`; the app DB creds (`kv/poker/db`)
  are read by the `terraform`/`ci-read` policies. So the poker-api rollout resolves
  `DATABASE_URL` with the **`terraform-local` AppRole** in its wrapper
  (`scripts/deploy-poker-api.sh`), NOT an in-playbook `ansible`-policy lookup. Don't widen
  the `ansible` policy to "fix" a permission-denied here — use the right token.

- **`kv/iac/minio` is scoped to the `tfstate` bucket ONLY** (see `reseed-minio-vault.sh`
  policy JSON). It cannot read app buckets like `co-latro-frontend`. Mint a separate
  bucket-scoped svcacct (`scripts/reseed-minio-frontend-vault.sh` → `kv/services/minio-frontend`)
  rather than reusing the tfstate credential.

- **nginx `default_server` clash.** A `listen 80 default_server` site (the co-latro frontend)
  collides with the distro's stock default site — `nginx -t` fails with a duplicate
  default_server error. Remove `/etc/nginx/sites-enabled/default` before reload, and always
  gate the reload behind `nginx -t` so a bad config can't take nginx down.

- **`mc mirror --remove` deletes web-root files absent from the bucket.** Intended (the web
  root mirrors the `co-latro-frontend` bucket = source of truth) — just don't hand-edit files
  under `/var/www/co-latro`; they'll be wiped on the next sync.

- **Backend `/health` is at the ROOT, not under `/api`.** nginx proxies only `/api/` → `:3020`,
  so `/health` is NOT reachable through nginx (the SPA fallback serves index.html for it). Health
  checks must hit `http://127.0.0.1:3020/health` directly on the box; smoke-test nginx with a real
  `/api/...` route instead.
