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
  `docs/runbooks/registry-import.md`.

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
  - ⚠ **The Ansible that line names did not exist until PET-378.** For a year the real
    mechanism was three one-off scripts for three named containers
    (`scripts/lxc-features-{232,235,241}.sh`), so a container created any other way got
    nothing — and because `features` is in `ignore_changes`, no plan ever said so.
    A survey on 2026-09-09 found **four of eighteen containers with no features at all**
    (109, 231, 237, 245) and one with half (236). CT 237 had been created that same day
    through the documented process. **Declare it instead:**
    `ansible/roles/lxc-features/defaults/main.yml` names every container's intended
    features, and `playbooks/configure-lxc-features.yml` converges them.
  - ⚠ **`pct set --features` REPLACES the whole string, it does not merge.** Setting
    `nesting=1,keyctl=1` on a container carrying `mount=nfs` silently drops the mount
    flag. Always pass the union of what is there and what you want.
  - ⚠ **`pct config` is not proof.** `features` only takes effect at container start, so
    a container can declare `nesting=1` and be running without it. The declared and the
    running state are read from two different places:
    - declared → the `features:` line of `pct config <vmid>`
    - running  → `/var/lib/lxc/<vmid>/config` and `.../rules.seccomp`, both of which
      Proxmox regenerates on every `pct start`. `nesting=1` writes
      `lxc.apparmor.allow_nesting = 1` into the config; **`keyctl=1` is an ABSENCE** —
      PVE implements it by deleting the `keyctl errno 38` line from `rules.seccomp`
      (`PVE/LXC.pm`), so reading that marker the obvious way inverts every result.

- **Missing `nesting=1` breaks systemd unit sandboxing, and the symptom depends on the
  systemd version (PET-377 / PET-378).** Without it the generated AppArmor profile carries
  `deny mount -> /proc/,` and `deny mount -> /sys/,`, so a unit that builds a mount
  namespace cannot start. Measured across ten Debian 13 / systemd 257 containers on pve03,
  same kernel and PVE build: `nesting=1` present → `tmp.mount`, `dev-mqueue.mount` and
  `run-lock.mount` **active, 10 of 10**; no features → the same three **failed, 3 of 3**.
  CT 236 isolates the flag — `nesting=1` with no keyctl, mount units healthy.
  - On **systemd 252** (Debian 12) the same denial kills **`systemd-logind` itself** with
    `226/NAMESPACE`, and every SSH login then waits 25 s for a logind that never answers.
    CT 109 is the lab's only systemd-252 container with no features and the only one with a
    dead logind; 104, 105 and 110 are the matched controls (same Debian, same systemd,
    features present, logind healthy).
  - ⚠ **The healthy featureless containers are not counterexamples**, and reading them as
    such cost a day. 231/237/245 run systemd 257, which survives the denial and only fails
    the mount units. Comparing 109 against 104 alone — both Debian 12 — hid the variable
    that mattered. **When two hosts differ in the thing you suspect but agree on the
    outcome, check what else differs before discarding the hypothesis.**

- **The loop reads live LXC config read-only — never with the mutation token.** Brownfield
  captures need the running `pct config` so the import plans as a no-op; the loop is
  author-only and must not guess specs on live hosts. `scripts/proxmox-ro-config.sh
  <node> <vmid>` GETs the config with a separate `PVEAuditor` token (`petedio@pam!loop-ro`,
  read-only, from Vault `kv/services/agent-loop`) — distinct from the full
  `petedio@pam!petedio` mutation token at `kv/iac/proxmox`. `apply`/`import`/state edits
  stay operator-only. See `docs/runbooks/loop-proxmox-readonly.md`.

- **Target the correct node endpoint.** bpg reads the PVE version from the endpoint
  and version-gates fields. Both survivors run 9.2.11 today, and `proxmox_endpoint`
  defaults to pve02 (`.11`); `.10` is pve03. Either answers for the cluster, but point
  at the node where the resources live when a version-gated field misbehaves.

- **Scoped API tokens use `--privsep 1` + an explicit ACL** (PET-55). A privsep token
  has its OWN permissions, independent of the user — and NONE until you grant them:
  `pveum acl modify / --tokens '<user>@pam!<id>' --roles PVEVMAdmin,PVEDatastoreUser`.
  That pair covers the IaC's VM/CT lifecycle + disk allocation while staying narrower
  than a `PVEAdmin@/` bootstrap token. Prove the new token refreshes clean BEFORE
  seeding it to Vault (the old token is the only fallback), and revoke the old one only
  after a CI apply is green.

- **History (pve01, dead 2026-09-03) — on pve01 the LAN/uplink bridge was `vmbr1`, NOT
  `vmbr0`.** On both survivors the LAN is `vmbr0`; this bites only when replaying a config
  recovered from pve01. `vmbr0` = `eno1`, a
  separate segment with no gateway — a container on it has an IP but cannot ARP the
  gateway (outbound 100% loss, DNS fails). `vmbr1` = `eno2`/`eno3`, where the
  working containers live. **Do NOT copy net config from a pve02 container** — on
  **pve02 the LAN bridge IS `vmbr0`** (single NIC `enp0s31f6`, VLAN-aware), the
  opposite of pve01. So `bridge` is per-node: `vmbr1` for pve01 resources, `vmbr0`
  for pve02. Discovered 2026-06-02 standing up the fresh MinIO (.221).

## Cluster + storage — pve02 + pve03 + QDevice (post 2026-09-03)

> **The next four bullets are pve01's R620.** That machine died on 2026-09-03 — its PERC H710
> failed electrically (`vault/Incidents/2026-09-03-rack-loss.md`) — so nothing below applies
> to a node you can reach. They stay because the next R620 will do the same things, and each
> one cost hours the first time.


- **Seven drives faulting in lockstep is the controller, not the drives — and a controller
  missing from inventory is not necessarily dead.** On 2026-08-28 pve01's SEL showed all seven
  drives `operating normally` then all seven `Fault detected` ~95 s later, twice; the H710 Mini
  was absent from both the hardware and firmware inventories and logged `Integrated RAID
  Controller 1 on NULL`. That looks exactly like a dead card. **It was a poorly seated one** —
  reseating it brought all seven drives back and the array imported with `/mnt/media` intact.
  It is a mezzanine card flat under two blue latches, not a PCIe card in a riser, so it seats
  unevenly. Reseat and cold-boot before ordering parts; a live card reports a firmware version
  in `Overview → Server → System Inventory`. RAID config lives on the disks, so import foreign
  VDs and **never create new ones**.

- **An open chassis stops an R620 booting, and fabricates drive faults.** With the cover off,
  pve01 reports `Server Status: ON` while drawing **0 Watts**; every power command appears to
  succeed and does nothing. It also logs seven simultaneous "Fault detected on drive N in disk
  drive bay 1" entries and `RAC0501: There are no physical disks to be displayed` — none of
  them real. The SEL says `The chassis is open while the power is on`. **Read the SEL before
  believing any storage fault on this machine.** Cost hours on 2026-08-28.

- **A LOM answering ping is NOT proof the host is running.** pve01's NICs stay powered from
  the standby rail via NC-SI, so both bridges answer IPv6 link-local with the machine at zero
  watts. The distinguishing test is TCP: a running host answers *something*. ICMPv6 replies
  with ports 22 and 8006 silent on both bridges means the host is down — go to iDRAC, not to
  the network.

- **iDRAC on pve01 is at `192.168.0.120`, the factory default, and is invisible to every
  normal scan.** It is on neither `.50` nor `.86` and answers no NDP multicast, so subnet
  sweeps find nothing. Reach it by aliasing the Mac onto that subnet
  (`sudo ifconfig en0 alias 192.168.0.240 255.255.255.0`). It is iDRAC7 **Enterprise**, so
  Virtual Console works — set Plug-in Type to HTML5 first or Launch downloads a Java `.jnlp`.
  pve01 is VGA-only and there is no VGA monitor here, so **this is the only way to see its
  screen**. Diagnose pve01 at iDRAC first, network second.

- **`.50` is NATed behind `.86`, so the two networks are nested, not isolated.** `.50` → `.86`
  works; `.86` → `.50` does not. Verified 2026-08-28 from pve02 (no `.86` leg, reached
  `.86.140:32400`) and from mission-control (`.86`-only, reached nothing on `.50`). This
  corrects `vault/Hosts/004-pete-pi.md`, which claims the `.86` leg is the only path to plex —
  it is not. **Pete-Pi is the jump host** from `.86` into `.50`: `ssh -A -i
  ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.86.46`. It also advertises both subnets on the
  tailnet — `tailscale-244` died with pve01 and pete-pi-1 took its routes
  (`environments/homelab/tailscale.tf`; verified `tailscale status` 2026-09-10).

- **`startup` is not declared in TF, so an apply strips it — keep it in `ignore_changes`.**
  Boot order and up/down delays are set on the node with
  `pct set <id> --startup order=N,up=S,down=S`. `modules/proxmox-lxc` declares no `startup`
  block, so without the `ignore_changes` entry the next apply-on-merge silently removes the
  ordering. Same class as `features` / `mount_point` / `idmap`: set out-of-band, ignored in
  state. The order is load-bearing on a cold start — postgres-231 must precede the apps
  holding connections to it. The boot-order tables in `docs/runbooks/lab-move.md` are pve01's;
  read the live order with `pct config <id> | grep startup` on each node before trusting one.

- **The cluster is two nodes plus a QDevice on pete-pi-1: 3 votes, quorum 2.** One node
  and the QDevice are quorate, so either node can be down without the other going read-only.
  `pvecm status` must show `A,V` on the QDevice line — `A,NV` means it is registered and
  votes for nobody (see `proxmox-ops`). Before the QDevice existed the cluster was
  `Expected votes: 2, Quorum: 2`, so a lone survivor was inquorate: `/etc/pve` mounted
  read-only and `pct start` refused every guest, and the only way out was `pvecm expected 1`
  on the survivor. Keep that command for the case where the QDevice is ALSO unreachable —
  never while the other node may be alive, which is how you split-brain.

- **pve03's NFS mounts from pve02 dictate power order.** pve02 exports `/mnt/media` and
  `/mnt/downloads` (ZFS) to pve03 only, and the arr stack there binds them with `shared=1`.
  A hard mount against a dead server never times out, so: **pve03 down first, pve02 down
  last; pve02 up first, pve03 second.** While pve02 is down the arr apps answer 200 and
  import nothing — `sonarr answered 200 for hours after the outage while holding 171 file
  records for files that no longer existed` is why `lab-verify.sh` probes the mounts, not
  the HTTP status. The lesson that survives from the old direction: a service that reads a
  mount it lost keeps serving its last view — verified 2026-08-29 on the registry, where
  `pct restart 106` left zot running with the empty catalog it started with. Restart the
  process that holds the file handles, not the guest.

- **pve02 + pve03 share `/etc/pve/storage.cfg`** — a storage entry without an explicit
  `nodes <name>` line is offered on BOTH nodes. Always scope node-local storage with
  `nodes pve02` / `nodes pve03`. pve02 has `local-lvm` (thin); pve03 has only the `local`
  directory store, so a `datastore_id` that works on one node fails on the other.

- **Stale node-name pin = silently "disabled" storage.** pve02 was once named `pete`;
  a `network-storage` entry pinned to `nodes pete` showed `disabled` in `pvesm status`
  forever (no such node). If a storage is mysteriously disabled, check its `nodes`
  line against `ls /etc/pve/nodes/`.

- **`content` must match what the storage actually is.** That same `network-storage`
  was declared `content rootdir,images` but its VG held plain ext4 filesystem LVs
  (NFS export mounts), not Proxmox image volumes — Proxmox would have tried to carve
  VM disks into a filesystem. Filesystem-mount LVs → register as a `dir` storage on
  the mountpoint, not as `lvm`.

- **pve02 is the homelab NFS file server — it is load-bearing, not idle.** Since the
  2026-09-04 rebuild it exports exactly two things, `/mnt/media` and `/mnt/downloads`, to
  `192.168.50.10` (`exportfs -v`). The three exports it used to carry —
  `/mnt/{nexus-data,backups,shared}` — did **not** survive: the `nexus-data` LV is gone,
  which is the second reason registry-106 cannot come back as it was (PET-389), and the
  Uptime Kuma backup that targeted `/mnt/backups` has skipped every run since (PET-386).
  Grep the estate for consumers before touching `nfs-server` on pve02.

- **The bridge numbers are INVERTED between the two nodes.** This is the single easiest way to
  strand a container:

  | | `vmbr0` | `vmbr1` |
  |---|---|---|
  | **pve01** (dead 2026-09-03) | `.86` Google mesh (no host IP) | `.50` LAN — `192.168.50.10` |
  | **pve02** | `.50` LAN — `192.168.50.11` | the dead VXLAN leg (`vxlan86`); nothing behind it |
  | **pve03** | `.50` LAN — `192.168.50.10` | *(does not exist)* — the `.86` presence is `wlo1`, `192.168.86.244` |

  Between the two survivors the LAN is `vmbr0` on both, so a plain `pct migrate` lands on the
  right network. The trap now bites when you **replay a config recovered from pve01**
  (`.agent/pve01-recovery/`): its `bridge=vmbr1` means the LAN there and nothing here.
  `pct migrate` moves a container without rewriting its bridge, so set it as part of the
  move, before starting it on the target:

      pct stop <id>; pct migrate <id> <target>
      pct set <id> -net0 name=eth0,bridge=<right one>,hwaddr=<KEEP IT>,...
      pct start <id>

  Keep the original `hwaddr` — DHCP reservations and firewall rules are keyed on it. This bit
  flaresolverr (102) during the PET-311 move to pve01 and is why `runner.tf` and `media.tf`
  both carry the warning inline.

- **A ping to the `.86` mesh from pve02 does NOT mean pve02 is on the `.86` network.** `.50` is
  NATed behind `.86`, so `.50 → .86` succeeds outbound and proves only that the gateway forwards.
  Whether a container on that node can *hold* a `.86` address is an L2 question, and the
  discriminator is **ARP**, not ICMP:

      arping -c2 -I vmbr0 192.168.86.1     # from pve02: zero replies -> no L2 path

  Beware the near-miss: `arping 192.168.86.140` (plex) DOES answer from pve02, because plex is
  dual-homed and its `.50` NIC replies for its `.86` address (Linux ARP flux, `arp_ignore=0`).
  The reply's MAC gives it away — it is the `.50` interface's. Always arping the **gateway**,
  which exists on one segment only.

  Consequence: pve02 has one physical NIC, on `.50`, so nothing there can serve the mesh clients
  directly. The live answer is not a second NIC: `roles/plex-bridge` runs a socat proxy on
  pete-pi-1 (`192.168.86.46:32400` → `.50.236`), the tailnet reaches 236 at `100.97.96.88`,
  and pve03's own `wlo1` carries the Palworld NAT. See `vault/Systems/plex-on-the-mesh.md`.

- **`pct migrate` refuses a container that has a snapshot**, with
  `can't migrate local volume '...': non-migratable snapshot exists`. It aborts in about two
  seconds having changed nothing — but if you stopped the guest first, it is now **down** and
  stays down until you start it again. Check `pct listsnapshot <id>` BEFORE stopping anything,
  and restore service first and think second. Hit on 112, the Cloudflare tunnel, which carried a
  six-month-old snapshot named `asdf`; the tunnel is every public hostname, so the cost of
  finding out the slow way is an outage of everything.

- **History — the VXLAN anchored on pve01 and died with it (2026-09-03).**
  `configure-mesh-vxlan.yml` and `roles/mesh-vxlan` are superseded by `roles/plex-bridge`; the
  mesh leg was removed from 236 in PET-332. The mechanism is kept because it worked and the MTU
  and gateway traps are general. **A node with one NIC can still hold an address on a network
  it has no cable to.** pve02 has a single port, on `.50`, and the TVs live on the `.86` mesh — which `.50` cannot be reached from,
  since `.50` is NATed behind `.86`. The fix needed no hardware: a **VXLAN** wraps mesh Ethernet
  frames in ordinary UDP addressed pve02 → pve01, and pve01 — which *is* cabled to the mesh —
  unwraps them into its own mesh bridge (`vmbr0`, port `eno1`). pve02 gets `vmbr1` backed only by
  the tunnel. The inner frame is never rewritten, so this is a real layer-2 presence: no NAT, no
  proxy, no custom access URLs, native client discovery, and the consumer mesh router needs no
  configuration at all. Managed by `ansible/playbooks/configure-mesh-vxlan.yml`.

  Two things to get right, both of which fail quietly:

  - **MTU.** VXLAN spends 50 of the underlay's 1500 bytes on headers, so the guest leg runs at
    **1450**. Leave it at 1500 and small packets pass while large ones vanish — it reads as an
    application bug, not a network one.
  - **Don't give the second leg a gateway** unless you mean to move the default route. 236 keeps
    its default on `.50` so the NFS media path is unchanged, and reaches `.86` as a
    directly-connected route. A gateway on both legs installs two default routes.

  The verification that actually proves it is ARP to the **gateway**, plus one better signal: the
  mesh router handed 236 an IPv6 address from its own advertisements, which only happens across a
  genuine L2 link.

- **`systemctl stop` is not `systemctl disable`, and the difference is a reboot.** When plex-gpu
  took over, 103 was stopped by hand — but left enabled, so the next container reboot would have
  put two Plex servers back on the network, with clients silently landing on whichever they saw
  last. Worse, the `plex` role hardcoded `enabled: true, state: started`, so the next
  `configure-media` run would have done the same thing sooner. Which server serves is now a
  variable (`plex_primary`) enforced by `plex-primary.yml`, and it sets **both** state and enabled.
  Any "temporarily turn this off" that is not also `disable`d is a pause, not a decision.
  103 died with pve01 on 2026-09-03, so `-e plex_primary=plex` cannot work any more;
  `plex-primary.yml` only asserts that 236 is running (PET-354).

## MinIO S3 state backend

- Needs `use_path_style = true` + all four `skip_*` flags
  (`skip_credentials_validation`, `skip_region_validation`, `skip_metadata_api_check`,
  `skip_requesting_account_id`). `region` is required by Terraform but ignored by MinIO.
- **S3-native locking** (`use_lockfile = true`, PET-105) — a conditional `If-None-Match`
  PUT of a `.tflock` object beside the state key, which modern MinIO supports. There is
  no DynamoDB table and none is needed. **Bucket versioning is still the safety net** —
  enable it (`mc version enable <alias>/<bucket>`) so a corrupt state can roll back.
- Backend creds come from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in your local
  environment. **CI sources every credential from Vault** — the four static Actions
  secrets were deleted in PET-29. Never inline creds in `backend.tf`.

## CI / runner

- The runner must live **inside** the homelab — a GitHub-hosted runner cannot route to
  `192.168.50.0/24` (Proxmox API + MinIO). `runs-on: [self-hosted, linux, x64, homelab]`.
- **Chicken-and-egg:** the runner is declared in `runner.tf`, but the first CI run needs
  a runner that doesn't exist yet. Break it by applying the runner LOCALLY once
  (`terraform apply -target=...container.runner`) + Ansible-registering it, then let CI
  take over.

## A Vault 403 says `permission denied` and means four different things (PET-355)

Bringing one new CD workflow up cost three failed deploys, because every cause returns
the identical body:

```
failed to retrieve vault token. code: ERR_NON_2XX_3XX_RESPONSE,
message: Response code 403 (Forbidden), vaultResponse: {"errors":["permission denied"]}
```

- **Wrong mount path.** The GitHub JWT backend is mounted at `jwt-github`, and
  `vault-action` posts to `auth/jwt/login` when `path:` is unset. Nothing is mounted
  there, so Vault refuses.
- **Wrong audience.** The roles bind `https://github.com/PeteDio-Labs`, and
  `vault-action` sends its own default when `jwtGithubAudience:` is unset.
- **Claim mismatch.** `bound_claims` does not match the token's `repository` or `ref`.
- **Missing or misnamed policy.**

**Read the audit log first, not the role.** `/opt/vault/logs/vault_audit.log` on 223
records the path Vault actually received, which is the only place the mount mistake is
visible. Filter for errors rather than for a path you assume:

```bash
pct exec 223 -- grep -a '2026-09-09T18:3' /opt/vault/logs/vault_audit.log \
  | python3 -c 'import json,sys
for l in sys.stdin:
    d=json.loads(l)
    if d.get("error"): print(d["time"][:19], d["request"]["path"], d["error"][:120])'
```

That printed `auth/jwt/login | permission denied` and ended the search. Auditing the
role first found nothing, because the role was correct all three times.

⚠ **Diff a new `vault-action` block against a working sibling line by line** before
debugging it. `petedio-water-fast`'s deploy is the reference and carries the warning
inline: `path: jwt-github # non-default mount — must be explicit or Vault 403s`. All
three defects were visible in that one diff; auditing the block against the playbook's
requirements instead found one at a time, over three merge-and-watch cycles.

## `runs-on: [self-hosted, homelab]` also matches the arm64 pi (PET-355)

Three runners carry `homelab`: runner-232 and runner-233 are x64, pete-pi-1 is arm64.
A job that does not pin the architecture lands on whichever is free.

The visible failure is `docker: permission denied` on the socket, and that is the lucky
outcome. **A job that compiles a binary on the runner and copies it to an amd64
container would build arm64, install it cleanly, and leave a service that cannot
execute** — a green deploy and a dead process. Pin
`runs-on: [self-hosted, linux, x64, homelab]`, as `petedio-water-fast` does.

## `become_user` needs sudo, and the minimal LXC template has none (PET-355)

`become_user` defaults to sudo. Containers built from the module's default Debian
template have no sudo unless a play installs it, so the task dies with
`/bin/sh: 1: sudo: not found` and `rc=127`.

`su` is not the fallback: service accounts here are created with
`shell: /usr/sbin/nologin` on purpose, and `su` refuses them.

**Use `runuser -u <user> -- <cmd>`.** It is in util-linux, is already present, and drops
to a nologin account without PAM. Verified on media-dash-237:

```
$ runuser -u mtrace -- id
uid=999(mtrace) gid=991(mtrace) groups=991(mtrace)
```

Running the check as root instead is the tempting fix and proves nothing — the point of
running as the service user is that it exercises the key's file mode.

## Scheduled workflows do not fire near their cron (PET-363)

`petedio-media-iac` declares `cron: "22 8 * * *"` and its run was created at `13:00:09`
UTC — four hours and thirty-eight minutes late. `petedio-iac`'s last three scheduled
runs landed at 12:57, 12:51 and 14:14, never near its declared 08:17.

GitHub delays these heavily and then releases them together, so **a stagger expressed in
cron minutes buys nothing**: eleven repos spaced five minutes apart still arrive inside
about forty minutes of each other. Spacing the crons is still right for the case where
they do fire on time, but do not rely on it to keep jobs off a contended runner.

## Uptime Kuma's `applyExisting` does not attach to existing monitors (PET-374)

- **`add_notification(isDefault=True, applyExisting=True)` created the channel and left
  all 19 monitors unattached.** The provisioner's own check caught it; without that check
  it would have shipped as a working alerting system wired to nothing. Set
  `notificationIDList` per monitor with `edit_monitor`, and keep a check that counts
  monitors with nothing attached and fails on any it finds. A monitor that notifies
  nobody looks exactly like one that does.

- ⚠ **`notificationIDList` has two shapes.** It is a **list** of ids on this Kuma
  (`[1]`), and a **dict** keyed by id in other versions and in `uptime-kuma-api`'s own
  docstrings. Assuming either crashes on the other — assuming dict gives
  `'list' object has no attribute 'get'`, and it is also what made the check report
  monitors unattached when they were already bound. Normalise both.

- **The provisioning config is deleted after each run**, so a later script cannot read
  credentials from `/root/.kuma-provision.json`. Get them from
  `kv/services/uptime-kuma` instead.

- **The socket cache lags the database.** `get_monitors()` right after a delete still
  returned the old count. `sqlite3 /opt/uptime-kuma/data/kuma.db` is authoritative:
  `SELECT COUNT(*) FROM monitor; SELECT COUNT(*) FROM monitor_notification;`

## Discord: an app can DM you with no shared server (PET-375)

- **`users.fetch(id).createDM().send()` works from a bot in zero guilds**, unprompted,
  with no DM opened first. Verified 2026-09-09 against `GET /users/@me/guilds` returning
  a count of 0. The documentation does not promise this, which is not the same as
  forbidding it — read it as describing what is guaranteed rather than what is permitted,
  and test rather than infer.

- **A user-installed app is `integration_types: [1]`** with `contexts: [0, 1, 2]`;
  `PRIVATE_CHANNEL` is only available to commands that declare it. The user context
  grants `applications.commands` and nothing else. Confirm the install actually happened
  with `GET /applications/@me` → `approximate_user_install_count`, which is separate from
  the command being registered.

- ⚠ **`Partials.Channel` is required to receive DMs.** Without it discord.js drops
  `messageCreate` for a DM channel it has not cached, so an app that lives only in DMs
  silently receives nothing — a failure indistinguishable from the privileged intent
  being off.

- **`GATEWAY_MESSAGE_CONTENT_LIMITED` is sufficient.** Toggling Message Content on for an
  app under 100 servers sets the *limited* flag, not the full one, and login succeeds.
  A check that tests for the full flag reports a failure that will not happen.

- **Defer before doing slow work.** Discord kills an interaction unacknowledged for three
  seconds; `deferReply` buys fifteen minutes. mtrace crosses six hosts over SSH, so
  without the defer the user sees "The application did not respond" while the work
  succeeds unseen.

## Vault seals every night, and two watchers open it (PET-373)

- **223 restarts nightly, so Vault seals nightly.** pve03's `vzdump` job runs at 02:45
  in `mode: stop`, so every guest on the node stops and starts. Vault comes back sealed
  and 223 boots around 02:48. That mode is correct and is not a bug to fix: pve03's
  guests sit on a plain directory store, where `mode: snapshot` degrades to a
  file-by-file rsync that never finishes, and `suspend` runs the same first pass. The
  measurements are in `ansible/roles/backup-store/tasks/jobs.yml`. Treat the nightly
  seal as permanent until pve03 gets snapshot-capable storage.

- **Two things unseal it, and that redundancy is deliberate.** `vault-unseal.timer` on
  pete-pi-1 is the primary, because the pi is always on. The launchd agent
  `dev.pdlab.vault-unseal` on the Mac stays installed as the fallback for when the pi
  is down or being rebuilt. They race every five minutes; the race is harmless, because
  whichever arrives first opens Vault and the other takes its early exit. **Do not
  remove the Mac agent** on the grounds that the pi covers it — that removes the only
  path that works when the pi does not.

- **The Mac alone was never enough.** launchd does not fire `StartInterval` jobs while
  the machine sleeps; it coalesces them into one run on wake. On 2026-09-09 the Mac
  slept on battery and Vault stayed sealed from 02:48 to 12:22, failing the nightly
  `infra-reconcile`. The two nights before, the same agent unsealed within two minutes.
  A watcher that depends on a laptop being awake works until the night it does not.

- **Unseal over the HTTP API, never `vault operator unseal`.** That command takes a
  positional `[KEY]` and has no stdin convention, so piping to it passes the literal
  `-` and Vault rejects it with a message about a bad hex or base64 string — which
  reads like a corrupt key and sends you off measuring byte lengths. `PUT /v1/sys/unseal`
  with the key in the request body also keeps it out of `ps` and out of shell history.

- **A sealed Vault already reads as DOWN in Uptime Kuma**, because the `vault` monitor
  accepts only 2xx and `/v1/sys/health` answers 503 when sealed. What Kuma cannot see is
  the *watcher* failing while Vault happens to be open, so the daily digest reports the
  timer's state and its last log line.

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

- **GitHub OIDC `sub` differs by event.** push-to-main →
  `repo:<owner>/<repo>:ref:refs/heads/main`; pull_request →
  `repo:<owner>/<repo>:pull_request`. Bind exactly the events that legitimately mint a
  token — never repository-only (any branch/workflow). **For `petedio-iac` the
  `github-actions` role is now MAIN-PUSH ONLY (PET-104):** the PR job moved to a
  GitHub-hosted, no-Vault `fmt`/`validate` (PR-controlled code must not run on the
  self-hosted LAN runner or mint creds), so there is no plan-on-PR to keep alive — do
  NOT re-add the `pull_request` sub here. The two-sub "bind BOTH" pattern still applies to
  roles whose repo genuinely runs a credentialed PR job (e.g. `media-ci`, `colatro-ci`
  until they get the same PET-104 treatment).

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

## Vault provider v5 — ephemeral reads + write-only (PET-190 / PET-107)

- **v5 needs Terraform ≥ 1.11 and `data` on `vault_kv_secret_v2` is deprecated.** The 4→5
  bump multiplexes the provider onto the Plugin Framework; `required_version` must be
  `>= 1.11` (the floor for ephemeral resources + `*_wo` args). Read a secret with
  `ephemeral "vault_kv_secret_v2"` instead of `data "..."` — its `.data` is the **same
  `map(string)`**, so only the keyword and lifecycle change; the `try(...data["key"])`
  access pattern carries over verbatim. `skip_child_token` and the `VAULT_ADDR`/`VAULT_TOKEN`
  env config are unchanged in v5 (v5 only stops *prompting* for address/token — it still
  errors if neither env nor config sets them, so the "validate needs VAULT_ADDR" rule holds).

- **Ephemeral values are context-restricted — that's the whole point, and it bites.** A
  value that references an ephemeral resource (directly or via a `local`) is itself
  ephemeral and may ONLY flow into: a **provider config** argument, a **write-only** (`*_wo`)
  resource argument, an `ephemeral = true` variable/output, or another ephemeral resource.
  Put it in a normal resource arg or a plain `output` and `terraform validate` hard-errors.
  Consequences for this repo: (a) the Postgres role password goes through
  `module owner_password` (declared `ephemeral = true`) into `postgresql_role.password_wo`,
  NOT `password` (the two are mutually exclusive); (b) the Cloudflare `api_token` (ephemeral)
  feeds only `provider "cloudflare" { api_token }`, while the **non-secret** account/zone/tunnel
  IDs had to MOVE OUT of the KV read to plain `TF_VAR`s — a KV v2 read is all-or-nothing, so
  keeping a `data` source just for the IDs would re-leak the token into state, and the IDs feed
  a data-source arg + outputs (non-ephemeral contexts) so they can't ride the ephemeral read.

- **Write-only passwords are diff-invisible → `password_wo_version` is the rotation lever.**
  `postgresql_role.password_wo` (cyrilgdn/postgresql ≥ 1.26) is never in the plan, so changing
  the Vault value alone does NOT trigger a re-apply. Bump the paired
  `password_wo_version` (here `var.poker_db_password_version` / `var.admin_db_password_version`)
  to push a rotated password through. This is a behaviour change from the v4 data-source model,
  where a rotated Vault value flowed through automatically on the next apply.

- **`terraform init -upgrade` collapses the lockfile to the LOCAL platform only.** Running
  it on macOS rewrote each provider's hashes down to `darwin_arm64`, dropping the
  `linux_amd64` entry the self-hosted runner needs — a green local validate that would fail
  `init` on the CI runner. After an upgrade, restore multi-platform coverage with
  `terraform providers lock -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64`
  in every root whose lock changed (registry-only, no LAN/Vault). Verify ≥1 `h1:` per provider
  per platform before committing.

## App rollout — Co-latro / poker-api 230 (PET-12/43/44) — history: torn down 2026-09-08 (PET-366)

- **The `ansible` Vault policy can't read `kv/poker/*` — by design.** Least-privilege:
  Ansible host-config reads `kv/iac/*` + `kv/services/*`; the app DB creds (`kv/poker/db`)
  are read by the `terraform`/`ci-read` policies. So the poker-api rollout resolves
  `DATABASE_URL` with the **`terraform-local` AppRole** in its wrapper
  (`scripts/deploy-poker-api.sh`), NOT an in-playbook `ansible`-policy lookup. Don't widen
  the `ansible` policy to "fix" a permission-denied here — use the right token.

- **The poker-api rollout's secrets span TWO policies → log in TWICE.** `kv/poker/db` is
  readable only by `terraform`/`ci-read`; `kv/services/{registry,minio-frontend}` (there is no `kv/services/nexus` — that guess shipped a broken deploy in PET-99) only by
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
  `playbooks/configure-lxc-features.yml`, PET-378). nesting+keyctl are necessary but NOT sufficient for faasd.

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

- **Private-registry pulls (Zot on registry-106 — down since 2026-09-03 with no blob store left, PET-389): creds go in `/var/lib/faasd/.docker/config.json`** (PET-88),
  standard Docker format `{"auths":{"docker.pdlab.dev":{"auth":"<base64 user:pass>"}}}` — NOT
  `~/.docker/...` and NOT a faasd CLI flag. `docker.pdlab.dev` is publicly-trusted, so (like Docker
  on 230) **no CA install / insecure-registries** is needed — only the auth. Written `0600` by
  `configure-openfaas.yml`; restart **`faasd-provider`** (the puller) to pick up a change. Don't
  create it with `docker login` on macOS — the helper leaves an empty `auth` (templating it is why
  the play builds the base64 itself).

## agent-loop host (242) — toolchain (PET-125/131/139/140) — history: fleet retired 2026-07-21, host destroyed 2026-08-24 (PET-307)

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

## Cloudflare — tunnel ingress + Access (PET-35/187/38)

- **v5 `cloudflare_zero_trust_access_application.policies` is a list of OBJECTS, not IDs.**
  `policies = [cloudflare_zero_trust_access_policy.route[k].id]` PASSES `terraform validate` (a
  `for_each` resource id is unknown at validate time, so element typing is skipped) but **fails
  the apply plan** with `Inappropriate value for attribute "policies": element 0: object
  required, but have string` — the classic validate-green / apply-red trap, and it only surfaces
  on the apply-on-merge runner. Use the object form:
  `policies = [{ id = cloudflare_zero_trust_access_policy.route[k].id }]`. (`modules/cloudflare-ingress`.)

- **Access policy `include` is v5 attribute syntax**, not v4 blocks:
  `include = [{ email = { email = "x@y" } }]` / `[{ email_domain = { domain = "y" } }]` /
  `[{ everyone = {} }]`. The v4 `include { email = [...] }` block form fails validate on `~> 5`.

- **Fail-closed an Access-gated route.** A public CNAME must not be created before its Access
  app, or a missing token scope / Zero-Trust-org error mid-apply leaves the hostname routed but
  **ungated**. `cloudflare_dns_record.route` carries
  `depends_on = [cloudflare_zero_trust_access_application.route]` so a failed Access create leaves
  no resolvable hostname. Relatedly, the CF API token (`kv/iac/cloudflare`, the
  `homelab-tunnel-management` token) needs **Account · Access: Apps and Policies · Edit** on top
  of Tunnel + DNS — and the apply only fails on a missing Access scope AFTER merge.

- **Authentik OIDC as a Cloudflare Access login method** (PET-38) has two traps: (1) the
  Authentik provider's **authorization flow must be implicit-consent** — explicit-consent
  silently breaks CF's machine redirect; (2) **endpoint path asymmetry** — `authorize`/`token`
  are GLOBAL (`https://auth.pdlab.dev/application/o/...`) but `jwks`/`.well-known` are
  **per-slug** (`.../application/o/<app-slug>/...`); wrong slug placement = login fails. CF's
  callback is `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`. The runbook that
  held the full procedure went with the fleet on 2026-07-21; `scripts/reseed-authentik-oidc-vault.sh`
  re-seeds the app's OIDC secret.

## Terraform — a local plan/apply is NOT the same plan CI runs

- **`terraform apply` from a laptop, with no extra env, plans to DESTROY the resource pool and
  every one of its memberships.** `var.manage_resource_pool` defaults to **false** (PET-160,
  after the PET-159 poison-pill incident), while CI sets `TF_VAR_manage_resource_pool` from the
  repo variable `MANAGE_RESOURCE_POOL`, which is **true**. So the pool exists in state, and any
  local run without the variable sees `count = 0` and proposes removing it. Nothing warns you;
  it just appears in the plan as destroys alongside whatever you were actually changing.

  **The count grows with the lab** — it was 7 memberships (8 destroys) when this was written and
  is 13 (14 destroys) once PET-355 added media-dash-237 and backfilled plane-235. Do not
  pattern-match on the number; match on the resource type, `proxmox_pool_membership.lxc[*]`
  plus `proxmox_virtual_environment_pool.homelab[0]`.

  **There is a second variable, and it hides** because it produces a quiet
  `1 to change` rather than a destroy: `TF_VAR_postgres_db_password_versions`, from the repo
  variable `POSTGRES_DB_PASSWORD_VERSIONS` (today `{"plane":2}`). Without it the plan proposes
  `password_wo_version = "2" -> "1"` on `module.postgres_db["plane"].postgresql_role.owner`,
  which is an unrequested password rotation on the tracker's database.

  Export both before any local plan. Read them off the repo rather than trusting this file,
  since both are repo variables and can change without a commit here:

  ```bash
  gh variable list --repo PeteDio-Labs/petedio-iac
  ```

  Treat **any** destroy in a plan whose change was additive as a STOP: check whether it belongs
  to a gate you didn't set rather than to your edit.

  This surfaced twice. First during the databases.tf consolidation, where the real change was
  `2 to import, 1 to add, 1 to change, 0 to destroy`. Then again in PET-355, where adding one
  container planned as `1 to add, 1 to change, 12 to destroy` locally and `1 to add, 0 to
  change, 0 to destroy` once both variables were set. Both times every extra line was
  pre-existing drift between the local and CI variable sets, and nothing to do with the edit.

- **Adding a Postgres database now touches one file** (`environments/homelab/databases.tf` —
  one entry in `local.postgres_databases`), but its secret must be readable by **ci-read**
  before the merge that adds it. That grant lives in the `vault-config` root, which is
  operator-applied via `scripts/apply-vault-config.sh` and **never runs in CI** — so it does not
  land with a normal merge, and apply-on-merge fails on a permission denied it cannot diagnose
  for itself.

## Claude Code as a service — the Claude host (247) (PET-396)

- **Remote Control and the Chrome integration both refuse API keys and long-lived
  `claude setup-token` tokens.** Each needs an interactive claude.ai login on a Pro, Max,
  Team or Enterprise plan. That removes the unattended provisioning path entirely: a play
  can install Claude Code, render its units and set every variable, and the host still
  cannot serve until a human runs `/login` over SSH. Plan the rollout as two phases and
  leave the units **stopped** in phase one — a server started without an eligible login
  exits immediately, and an unbounded `Restart=always` turns a missing step into a crash
  loop that reads like a broken host. Bound it with `StartLimitIntervalSec` +
  `StartLimitBurst` in `[Unit]` so it lands in `failed` instead, and remember that clearing
  `failed` needs `systemctl reset-failed` before the next start will be accepted.

- **`-e var=false` is a truthy STRING, so an enable gate needs `| bool` on every read.**
  Ansible's `-e key=value` never yields a bool. `{{ 'started' if enable else 'stopped' }}`
  evaluates to `started` under `-e enable=false`, while a sibling `enabled: "{{ enable }}"`
  goes through Ansible's own coercion and says false — leaving a **running, disabled** unit.
  Worse, a `when: not enable | bool` elsewhere in the play *does* coerce, so the closing
  message cheerfully reports the units as stopped. Found in review of PET-396; it is the
  green-check-over-work-that-never-happened shape in miniature, inside one play.

- **`bypassPermissions` is refused as root and under `sudo` on Linux.** A unit that runs
  the server as root fails at startup, so the dedicated non-root user is a requirement of
  the mode, not hygiene. The check is skipped inside a recognized sandbox, which an LXC is
  not.

- **Flags go AFTER the `remote-control` subcommand.** A global `claude` flag placed before
  it is not carried over to the sessions the server creates, and Claude Code refuses to
  start rather than run them with less than you asked for, naming the flag to move. So
  `claude remote-control --permission-mode X` works and `claude --permission-mode X
  remote-control` does not — which looks like the same command to anyone tidying a unit file.

- **Four telemetry opt-outs disable Remote Control, and it does not present as a setting.**
  `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and
  `DISABLE_GROWTHBOOK` each disable the feature-flag evaluation the feature's availability
  depends on, wherever they are set — shell, unit, or a `settings.json` `env` block. The
  symptom is "unavailable", which reads like an outage rather than something you chose.

- **The startup trust dialog never saves trust for a home directory.** Start the first
  session from a project directory, or Remote Control refuses to run later for a reason
  that points nowhere near the trust prompt you clicked past weeks ago.

- **`claude -p` skips the trust dialog entirely, so trust is not a constraint on an
  unattended job** (`claude --help`, under `-p`: the dialog is skipped whenever Claude runs
  non-interactively, which includes any run whose stdout is not a TTY). Read that both
  ways. It means the PET-399 work loop can run in a directory nobody ever trusted by hand,
  which is what lets it keep its own clone instead of sharing the one a human drives. It
  also means a piped `claude` in a directory you did not mean to trust does not stop to
  ask. Trust the directory anyway if you want MCP tools resolving in that session.

- **There is no `--max-turns` in Claude Code 2.1.x.** An unattended `claude -p` has no
  turn ceiling, so wall-clock is the only bound available: `timeout` around the process,
  and a `TimeoutStartSec` above it in the unit so the inner one reports first and says why.
  Checked against `claude --help` on 247 while writing the loop — a `--max-turns` copied
  out of an older runbook fails the whole invocation rather than being ignored.

- **Nothing about this host needs `features{}`** — no Docker, so no nesting, no keyctl, and
  no `scripts/lxc-features-<id>.sh` step on the node. Worth stating because the reflex on
  this cluster is that every app LXC needs the root@pam dance. It is also worth *keeping*
  true: the day something here wants Docker is the day this host gains an out-of-band step
  that every rebuild has to remember.

- **Remote Control opens no inbound port.** The session registers with the Anthropic API
  over outbound HTTPS and polls it, so the most remotely-reachable box in the lab needs no
  Cloudflare route, no UFW rule and no port forward. The corollary is that liveness cannot
  be checked by connecting to it: `lab-verify` asserts an established outbound :443
  connection instead, because an `active` unit with an expired login looks identical to a
  working one.

- **Debian's `.bashrc` returns early for non-interactive shells, so a PATH line appended
  there is invisible to `su - user -c ...` and to systemd.** Not Claude-specific, but it is
  exactly the trap that makes a health check report a working host as broken: set `PATH`
  explicitly in the unit, and use absolute paths in checks.

- **Chrome integration cannot be satisfied by a browser on the node.** It pairs over native
  messaging — a local pipe keyed to a file in the session user's own home — so Claude Code
  and the browser must be the same user on the same machine, and headless is unsupported
  (browser actions run in a visible window). A browser on the hypervisor next to a Claude
  Code LXC pairs with nothing. Evaluated and dropped for 247; if it is ever wanted, it costs
  a desktop and a remote-desktop transport **inside** the container.

## `ansible-lint <dir>` can examine nothing and call it a pass (PET-397)

- **`ansible-lint .` run inside `ansible/` reports `Passed: 0 failure(s), 0 warning(s) in 0
  files processed of 1 encountered` and exits 0.** It is not linting the tree; it is linting
  nothing and saying so in a line nobody reads. Pass explicit targets — `ansible-lint roles/
  playbooks/` processes 186 files here — and assert the processed count in CI.

- **Zero is the wrong threshold for that assertion.** Once a `.ansible-lint` config exists in
  the directory, the same collapsed invocation reports `1 files processed`, still green. A
  guard written as `-eq 0` passes it. Floor the count against something that grows with the
  repo instead: `.github/workflows/ansible-validate.yml` uses roles + playbooks, counted in
  an earlier step that itself refuses to continue on zero.

- **`syntax-check[unknown-module]` usually means a missing collection, not a typo.** Nine of
  them appear across this repo until `ansible-galaxy collection install -r
  ansible/requirements.yml` has run. They are deliberately NOT suppressed with `# noqa`, so a
  silently failed collection install turns the check red rather than skipping those files.

- **There is no ignore file — suppress at the site, with the reason.** The tree lints clean
  at the `production` profile. Eleven findings were deliberate and carry `# noqa: <rule>`
  where the code is, with the why above them. Three of those are worth knowing before you
  "tidy" one: `apt-get -s upgrade` in `apt-hygiene` is a SIMULATION whose stdout is parsed —
  the `ansible.builtin.apt` form would actually upgrade ~190 packages on pve03;
  `systemctl start --wait` in `vault-unseal` propagates the oneshot's exit code, which
  `systemd_service: state=started` discards; and the reboot in `ollama-service` must precede
  the `nvidia-smi` assert in the same play, so it cannot become a handler.

- **`set -o pipefail` needs `executable: /bin/bash`.** `/bin/sh` is dash on Debian and
  answers `Illegal option -o pipefail` with rc=2. Fixed once on runner-233 (`6cb5bfb`), and
  again in `configure-openfaas.yml` when the lint backlog was cleared. If you add a pipeline
  to a `shell:` task, add the `args: executable:` in the same edit.

- **Renaming a handler breaks every `notify:` that names it.** PET-303 did exactly that and
  left a dangling notify. When `name[casing]` makes you capitalise a handler, grep the repo
  for the old string and move the notifies in the same commit — `Restart zot` alone has four.

## A sudoers grant belongs to the UID, not to the process you wrote it for (PET-408)

- **If a program runs a `claude -p` session as its own user, that session inherits every
  sudo grant the program has.** The PET-399 loop shipped with `/etc/sudoers.d/claude-loop`
  granting `claude` two exact broker commands, no wildcards, `visudo`-validated — a
  textbook-narrow grant. It was still wrong, because the tick ran as `claude` and started a
  session as `claude`, and the session's instructions come from a Plane work item. Anyone
  who could write one could run the granted command directly and skip every guard in the
  tick. Narrowing *which* commands a grant covers does nothing about *who* can call them.

- **Invert the privilege instead of reaching up through it.** The unit now runs as root,
  reads `/etc/claude-loop/` directly and calls `runuser -u claude` for the session and for
  every command that touches the working tree. `runuser` drops privilege and cannot raise
  it, so there is no grant to inherit and no sudo on the host at all.

- **`runuser` lives in `/usr/sbin`, which is not on a non-root `PATH`.** A tool check that
  demands it unconditionally fails a hand-run as the unprivileged user for a reason that has
  nothing to do with the problem. Require it only when `id -u` is 0, and set the unit's
  `PATH` explicitly — Debian's `.bashrc` returns early for non-interactive shells, so the
  role's `PATH` line never runs under systemd.

- **`HOME` does not follow `runuser -u`.** A root unit whose `Environment=HOME` points at
  `/root` makes `claude -p` look for the claude.ai login in the wrong place and report
  itself as not logged in. Set `HOME` to the session user's home in the unit.

- **A root process pushing from a user-owned clone must push to a URL, not to `origin`.**
  Pushing to a named remote updates that remote's tracking ref, which writes a root-owned
  file into a `claude`-owned `.git` and breaks the next session with objects it cannot
  touch. Pushing to an explicit URL updates no tracking ref, so root only reads the
  repository — and a session that repointed `origin` cannot redirect the push at all. Git
  also refuses a repository owned by another user, so the push needs
  `-c safe.directory=<path>`, scoped to that path and never `*`.

- **Removing a grant means removing the file, not deleting the template.** A host converged
  before the fix keeps `/etc/sudoers.d/claude-loop` forever if the role simply stops
  rendering it. Reconcile what you removed with `state: absent`, the same way the role
  already reaps undeclared `claude-remote-*` units.
