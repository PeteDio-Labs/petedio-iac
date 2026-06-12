# GOTCHAS — hard-won patterns for this stack

Carry-forward lessons. Every story that hits a new one appends here (Definition of Done).

## Proxmox / bpg

- **bpg import never round-trips** `operating_system.template_file_id`, `features`,
  `initialization.user_account`. Always `lifecycle { ignore_changes = [...] }` them,
  or every plan shows phantom drift.

- **Brownfield-capturing a community-scripts LXC diverges from the greenfield module
  defaults — match it exactly or the import is NOT a no-op** (PET-122, Nexus 106). A
  "Docker LXC" created by the community-scripts installer (not by `modules/proxmox-lxc`)
  differs in ways that each force a destroy/recreate or a live-behaviour change if you
  don't match them: (a) its NIC is named **`eth1`**, not `eth0` — renaming recreates the
  interface (new MAC, network blip) → `network_interface_name`; (b) **pin the running
  `hwaddr`** via `mac_address` so the import doesn't rely on computed-value preservation;
  (c) it sets **no** `nameserver`/`searchdomain` (inherits the host resolv.conf) — render
  no `dns` block (`dns_servers = []`) or the plan writes resolver config into a live host;
  (d) host-path **bind mounts** (`mp0 /mnt/pete/… -> /…`, e.g. Nexus's NFS-backed blob
  store) and the raw `lxc.idmap`/`apparmor` lines are set out-of-band on the node — bind
  mounts hit the **same `root@pam` API restriction as features**, so the token can't manage
  them; keep `mount_point` in `ignore_changes`. (e) **bpg round-trips `idmap` and `console`
  on import** — they are NOT invisible raw `lxc.*` config (only the apparmor line is). An
  unaware first plan tries to **strip the idmap** — on CT106 that mapping (host 200 ↔
  guest 200) is what makes the NFS blob store writable in-guest — so both sit in
  `ignore_changes` too. Read the live config read-only first
  (`scripts/proxmox-ro-config.sh <node> <vmid>`) and expect only **cosmetic**
  `description`/`tags` diffs after import, plus state-side noise (`+ vm_id`, `+ timeout_*`
  — provider attributes import doesn't populate, not API mutations). Full procedure:
  `docs/runbooks/nexus-import.md`.

- **More brownfield divergences, from the Authentik capture** (PET-123, LXC 119): not every
  captured LXC is a community-scripts box, but the same "match it exactly" rule applies to
  whatever the live config shows. Two new ones beyond the Nexus list: (a) **`net0
  firewall=1`** — the module's NIC firewall defaults off, so a live container with the
  Proxmox NIC firewall ON needs `network_interface_firewall = true` or the import plans to
  **disable the firewall on a live host**; (b) a container that sets a **`nameserver` but no
  `searchdomain`** (e.g. CT119) needs `dns_servers=[…]` **with** `dns_domain = ""` — the
  module renders `domain = null` when empty so it doesn't write a searchdomain that wasn't
  there. Also set `os_type` to the live `ostype` (CT119 is `ubuntu`, not the `debian`
  default). Full procedure: `docs/runbooks/authentik-import.md`.

- **Proxmox API tokens can't set LXC `features{}`.** The API enforces a hardcoded
  `user == root@pam` check for features other than bare `nesting`; an API token's
  username is `root@pam!tokenid`, not `root@pam`, so it fails — even for a PVEAdmin
  token. **Workaround:** TF creates the LXC *without* a `features{}` block; Ansible
  (or `pct set <id> --features nesting=1,keyctl=1` over ssh-as-root) sets them
  out-of-band. Keep `features` in `ignore_changes`.

- **The loop reads live LXC config read-only — never with the mutation token.** Brownfield
  captures need the running `pct config` so the import plans as a no-op; the loop is
  author-only and must not guess specs on live hosts. `scripts/proxmox-ro-config.sh
  <node> <vmid>` GETs the config with a separate `PVEAuditor` token (`petedio@pam!loop-ro`,
  read-only, from Vault `kv/services/agent-loop`) — distinct from the full
  `petedio@pam!petedio` mutation token at `kv/iac/proxmox`. `apply`/`import`/state edits
  stay operator-only. See `docs/runbooks/loop-proxmox-readonly.md`.

- **Target the correct node endpoint.** bpg reads the PVE version from the endpoint
  and version-gates fields. Cluster nodes can differ (pve01 9.1.x). Point
  `proxmox_endpoint` at the node where the resources live.

- **Scoped API tokens use `--privsep 1` + an explicit ACL** (PET-55). A privsep token
  has its OWN permissions, independent of the user — and NONE until you grant them:
  `pveum acl modify / --tokens '<user>@pam!<id>' --roles PVEVMAdmin,PVEDatastoreUser`.
  That pair covers the IaC's VM/CT lifecycle + disk allocation while staying narrower
  than a `PVEAdmin@/` bootstrap token. Prove the new token refreshes clean BEFORE
  seeding it to Vault (the old token is the only fallback), and revoke the old one only
  after a CI apply is green.

- **On pve01 the LAN/uplink bridge is `vmbr1`, NOT `vmbr0`.** `vmbr0` = `eno1`, a
  separate segment with no gateway — a container on it has an IP but cannot ARP the
  gateway (outbound 100% loss, DNS fails). `vmbr1` = `eno2`/`eno3`, where the
  working containers live. **Do NOT copy net config from a pve02 container** — on
  **pve02 the LAN bridge IS `vmbr0`** (single NIC `enp0s31f6`, VLAN-aware), the
  opposite of pve01. So `bridge` is per-node: `vmbr1` for pve01 resources, `vmbr0`
  for pve02. Discovered 2026-06-02 standing up the fresh MinIO (.221).

## pve01 / pve02 cluster + storage (PET-127)

- **pve01 + pve02 are a quorate 2-node cluster** ("Homelab"), so `/etc/pve/storage.cfg`
  is **cluster-shared** — a storage entry without an explicit `nodes <name>` line is
  offered on BOTH nodes. Always scope node-local storage with `nodes pve01` / `nodes pve02`.

- **Stale node-name pin = silently "disabled" storage.** pve02 was once named `pete`;
  a `network-storage` entry pinned to `nodes pete` showed `disabled` in `pvesm status`
  forever (no such node). If a storage is mysteriously disabled, check its `nodes`
  line against `ls /etc/pve/nodes/`.

- **`content` must match what the storage actually is.** That same `network-storage`
  was declared `content rootdir,images` but its VG held plain ext4 filesystem LVs
  (NFS export mounts), not Proxmox image volumes — Proxmox would have tried to carve
  VM disks into a filesystem. Filesystem-mount LVs → register as a `dir` storage on
  the mountpoint, not as `lvm`.

- **pve02 is the homelab NFS file server — it is load-bearing, not idle.** It exports
  `/mnt/{nexus-data,backups,shared}` over NFS; pve01 host-mounts all three as
  `/mnt/pete/*`. The cluster `pete-backups` storage IS pve02's HDD over NFS, and
  **Nexus's blob store (CT106) is an NFS mount of pve02's `/mnt/nexus-data`** — never
  touch that export or `nfs-server` on pve02 or you break `docker.pdlab.dev`.

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

- **`terraform validate` still needs `VAULT_ADDR` set** even though it never connects.
  The `vault` provider's `address` is a required argument; with no `VAULT_ADDR` in the
  env, `validate` fails with `Missing required argument … "address"` (not a connection
  error). CI pins it in the job `env:`; locally export it before `validate`/`plan`.

- **CI→Vault cutover is lockout-guarded (PET-29).** vault-action's `$GITHUB_ENV` exports
  OVERRIDE job-level `env` defaults, so the static repo secrets and the Vault path
  co-exist harmlessly (statics are dead weight once Vault works). Delete the static
  fallback secrets ONLY after a Vault-only apply is green on `main` — never in the same
  change that removes their last reference.

## App rollout — Co-latro / poker-api 230 (PET-12/43/44)

- **The `ansible` Vault policy can't read `kv/poker/*` — by design.** Least-privilege:
  Ansible host-config reads `kv/iac/*` + `kv/services/*`; the app DB creds (`kv/poker/db`)
  are read by the `terraform`/`ci-read` policies. So the poker-api rollout resolves
  `DATABASE_URL` with the **`terraform-local` AppRole** in its wrapper
  (`scripts/deploy-poker-api.sh`), NOT an in-playbook `ansible`-policy lookup. Don't widen
  the `ansible` policy to "fix" a permission-denied here — use the right token.

- **The poker-api rollout's secrets span TWO policies → log in TWICE.** `kv/poker/db` is
  readable only by `terraform`/`ci-read`; `kv/services/{nexus,minio-frontend}` only by
  `ansible`. **No single token reads both.** `deploy-poker-api.sh` logs in with each AppRole
  for its own domain. When the rollout moves to the runner (OIDC CD-on-merge), the **`ci-read`**
  policy reads `kv/poker/*` but **not `kv/services/*`** — grant it `kv/data/services/nexus` +
  `kv/data/services/minio-frontend` (or relocate those creds) before the runner can deploy.

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

## OpenFaaS / faasd (PET-86)

- **Creating an LXC NIC needs `SDN.Use` on the bridge's SDN zone** (newer Proxmox). The IaC
  token 403s on create: `Permission check failed (/sdn/zones/localnetwork/vmbr1, SDN.Use)`.
  LXCs 230/231/232 predate this enforcement. Fix once, out-of-band (root@pam on the node):
  `pveum role add IaCSDNUser -privs "SDN.Use,SDN.Audit"` then
  `pveum acl modify /sdn/zones/localnetwork -roles IaCSDNUser -tokens 'petedio@pam!iac' -users 'petedio@pam'`.

- **faasd in an unprivileged LXC needs `/dev/net/tun`** for its CNI bridge. Without it the
  gateway/functions deploy but get no network (invokes hang / "no route to host"). Pass it
  through on the node: `pct set <id> -dev0 /dev/net/tun,mode=0666` + reboot (the line is in
  `scripts/lxc-features-241.sh`). nesting+keyctl are necessary but NOT sufficient for faasd.

- **faasd basic-auth secret files must be `0644`, not `0600`.** The gateway runs as a NON-root
  user and bind-mounts `/var/lib/faasd/secrets/basic-auth-{user,password}` → `/run/secrets`.
  With `0600 root:root` it can't read them and **silently exits** — and since the gateway is the
  ONLY core service that reads basic-auth, only it dies (nats/prometheus/queue-worker stay up),
  masquerading as a CNI "no route to host" on `:8080`. faasd's own generated secrets are `0644`.

- **Don't PUSH a custom gateway password — let faasd own it and CAPTURE it.** Overwriting
  basic-auth-password from Vault + restarting faasd proved unreliable: the gateway returned 401
  to its *own* on-disk password (confirmed via raw `curl`, so not a faas-cli quirk) even after a
  full container recreate — worst on gateway **0.27.12**. Working model: let `faasd install`
  generate the password (gateway image must be **>= 0.27.13**), then read
  `/var/lib/faasd/secrets/basic-auth-password` and seed it into Vault. See
  `ansible/playbooks/configure-openfaas.yml` (capture model) + `scripts/deploy-openfaas.sh`.

- **`faasd install` must run from the faasd source-clone dir.** It reads `./hack/*.service`
  templates relative to CWD; run elsewhere and it errors *after* truncating
  `/var/lib/faasd/docker-compose.yaml` to 0 bytes → `faasd up` then fails with
  "Top-level object must be a mapping" and crash-loops. Recover by restoring the compose from
  the clone: `cp /opt/faasd-src/docker-compose.yaml /var/lib/faasd/`.

- **Private-registry (Nexus) pulls: creds go in `/var/lib/faasd/.docker/config.json`** (PET-88),
  standard Docker format `{"auths":{"docker.pdlab.dev":{"auth":"<base64 user:pass>"}}}` — NOT
  `~/.docker/...` and NOT a faasd CLI flag. `docker.pdlab.dev` is publicly-trusted, so (like Docker
  on 230) **no CA install / insecure-registries** is needed — only the auth. Written `0600` by
  `configure-openfaas.yml`; restart **`faasd-provider`** (the puller) to pick up a change. Don't
  create it with `docker login` on macOS — the helper leaves an empty `auth` (templating it is why
  the play builds the base64 itself).

## agent-loop host (242) — toolchain (PET-125/131/139/140)

- **npm globals for the loop must live in a USER-writable prefix, not `/usr`.** The loop
  runs as non-root `agent` (no sudo). Installing Claude Code / Bun as root into the system
  npm prefix (`/usr/lib/node_modules`) makes the agent's `npm -g` writes — including Claude
  Code's **auto-update** — fail with `Auto-update failed: no write permission to npm prefix
  · Run /doctor` (EACCES). Fix (PET-139): set the agent's npm prefix to `~/.npm-global`
  (role var `agent_loop_npm_prefix`, written to `~/.npmrc`), install both globals **as the
  `agent` user** into it, and put `~/.npm-global/bin` on PATH ahead of `/usr/bin` so the
  user-owned, self-updatable copy wins. Don't `chown -R` the system prefix or give the
  agent sudo — give it its own prefix. **Migration note:** a host first built by the old
  role still has the root-global copy in `/usr`; the new role leaves it **shadowed** (PATH
  prefers the agent copy) rather than removing it — reaping `/usr`'s copy live would break
  the running loop's tmux shell (cached `claude` path + a PATH set before the `.bashrc`
  edit). Remove it by hand (`npm rm -g …` as root) only while the loop is idle. A
  long-running `claude` keeps showing the warning until it's **restarted in a fresh shell**.

- **`community.general.pipx` needs pipx ≥1.7.0 — Ubuntu 24.04 apt ships 1.4.3.** Every pipx
  task fails `The pipx tool must be at least at version 1.7.0` if you rely on the apt
  package, so the loop's verify tooling (ansible-core / yamllint / ansible-lint) never
  installs. Install pipx via **pip** instead (`--break-system-packages`, since 24.04's
  python is PEP-668 externally-managed; system pip lands it in `/usr/local/bin`, ahead of
  `/usr/bin`) and reap the stale apt pipx. PET-140.

- **Vault Agent `remove_secret_id_file_after_reading` defaults to TRUE.** The loop reads its
  own secrets via a Vault Agent that auto-auths with the read-only `agent-loop` AppRole and
  sinks a renewing token to `~agent/.vault-token` — so `scripts/proxmox-ro-config.sh`'s Vault
  fallback works with no env var and no claude restart (the CLI reads the token off disk).
  But the Agent **deletes the `secret_id` file after first use** unless you set
  `remove_secret_id_file_after_reading = false`; without it an Agent restart (or Ansible
  re-run that re-templates the config) can't re-auth and the token sink goes stale. The host
  needs the `vault` binary too (the CLI/`vault agent` are one binary) — the helper's Vault
  fallback was dead weight until this. PET-141.
