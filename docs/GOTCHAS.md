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
