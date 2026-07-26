# lab-graph

Stateless, read-only topology aggregator for the homelab, running as an OpenFaaS function on faasd (LXC 241). Step 2 of the build order in the [VR Lab + Voice Capture](https://linear.app/petedillo/document/vr-lab-voice-capture-workflow-services-and-layer-model-aa7be334580a) doc, and useful with no headset at all.

```bash
curl http://192.168.50.241:8080/function/lab-graph
```

> The faasd gateway is firewalled to source `192.168.50.230` (PET-204/F1), so that call only works **from `.230` or on the box itself**. It is not reachable from the Mac, and that is not a fault.

## What it returns

One JSON document, ~12 KB, in about 80 ms:

| Key | What it carries |
| --- | --- |
| `nodes` | Both Proxmox nodes — status, CPU/mem, PVE version, and the LAN bridge (`vmbr1` on pve01, `vmbr0` on pve02 — a genuine trip hazard, not cosmetic) |
| `guests` | Every guest keyed on **VMID**, with its assigned block, seat, target VMID, and IaC coverage |
| `offcluster` | The two load-bearing hosts that are *not* Proxmox guests |
| `storage` | Every PVE pool, sorted by fullness |
| `storage_edges` | The cross-node NFS dependencies, flagged `load_bearing` |
| `warnings` | Drift, both directions (below) |
| `counts` | nodes / guests / running / stopped / offcluster |

## Design decisions worth knowing

**Layout is hand-authored, not derived.** `layout.json` maps VMID → block + seat. Deriving position from PVE API ordering would reshuffle the scene on every create/destroy, destroying the spatial memory that is the only reason to render the lab in space rather than as a list. A guest with no layout entry lands in `staging` and raises a warning — place it deliberately.

**Guests group by *assigned* function block, not live VMID.** This is the recommended answer to open decision 1 in the doc. Media's live VMIDs are 100–110 against a 21x target, and renumbering is deferred indefinitely (a VMID is fixed at creation, so renumber means destroy+recreate). Grouping by live VMID would bake that mismatch into the model permanently; `target_vmid` carries the aspiration alongside.

**Drift is reported in both directions.** The obvious one is a live guest missing from the layout. The one that actually bit us is the reverse — `113 dev-workstation` and `108 Minecraft` sat in the inventory doc as live for a month after they were destroyed. `declared_not_present` catches that. Both paths are tested.

**Secrets by reference.** The PVE token is a faasd secret mounted at `/var/openfaas/secrets/pve-ro-token`. It is never in the image, the stack file, the environment, or `faas-cli describe` output. `PVE_RO_TOKEN` exists only as a local-dev fallback.

**Read-only by construction.** The token is a PVEAuditor token and every call is a GET. There is no code path that mutates anything.

**Partial results beat a 500.** One node being unreachable produces a warning and the other node's guests, not a failed request.

**One cluster-wide GET.** `/cluster/resources` carries every guest's vmid/name/node/status/cores/mem/disk in a single call. Per-guest `config` would be 21 round trips for data already in hand — it is only needed for per-NIC detail.

## Known gaps

- **`/mnt/media` is invisible here.** It is a plain host mount, not a PVE storage pool, so it never appears in `/cluster/resources` — and it is the volume actually under pressure (84%, vs `sdb3-storage` at 66%). The `storage_pressure` warning cannot fire for it. Reading it needs either a node-level probe or a hand-declared entry.
- **Tailscale is `not_configured`.** Enumerating the tailnet needs a Tailscale **API** key; the key in `kv/services/tailscale` is a node **auth** key (single-use, for joining) and cannot query the API. Reported as not-configured rather than silently empty.
- **No MikroTik source.** The original draft assumed one; no reachable API was found. PVE is the confirmed topology source.
- **`iac_coverage` is hand-maintained** in `layout.json`. No API can answer "is this under IaC", so it drifts unless updated with the infra.
- **Off-cluster hosts are declared, never probed.** Reachability is a health question; this function answers topology.

## Local development

```bash
cd tools/lab-graph
vault kv get -field=proxmox_ro_token kv/services/agent-loop > /tmp/tok
PVE_TOKEN_FILE=/tmp/tok PORT=3999 bun run server.ts
curl localhost:3999 | jq .
```

## Deploy

```bash
scripts/deploy-lab-graph.sh
```

Builds on **runner-232** (native amd64 — the Mac is arm64 and its Docker daemon is often down), pushes to Nexus, then deploys from **on 241** over loopback because the gateway is firewalled to `.230`. Credentials come from Vault via the Keychain root token and are passed on **stdin, never argv**. The script's header comment explains each of those three choices.
