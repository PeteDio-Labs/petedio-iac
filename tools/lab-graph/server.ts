// lab-graph — stateless, read-only topology aggregator for the VR lab view.
//
// Polls the Proxmox read-only API and returns one normalized JSON document describing the
// homelab: nodes, guests (keyed on VMID), storage, and the layers the lab view renders.
// Never mutates anything: the PVE token is a PVEAuditor token and every call is a GET.
//
// Secrets by reference — the token is read from the OpenFaaS secret mount at
// /var/openfaas/secrets/pve-ro-token, never from an env var baked into the image.
// (PVE_RO_TOKEN is honoured as a local-dev fallback only.)
//
// See the "VR Lab + Voice Capture" Linear doc, §2 and §3.

import layout from "./layout.json";

const PORT = Number(process.env.PORT ?? 3000);
const SECRET_PATH = process.env.PVE_TOKEN_FILE ?? "/var/openfaas/secrets/pve-ro-token";
const TIMEOUT_MS = Number(process.env.PVE_TIMEOUT_MS ?? 6000);

const NODES = [
  { name: "pve01", endpoint: process.env.PVE01_URL ?? "https://192.168.50.10:8006" },
  { name: "pve02", endpoint: process.env.PVE02_URL ?? "https://192.168.50.11:8006" },
];

// PVE serves a self-signed cert. This is a LAN call to a pinned address over a token the
// caller already holds; cert verification adds nothing here and blocks the whole function.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

type Warning = { code: string; detail: string };

async function readToken(): Promise<string> {
  const f = Bun.file(SECRET_PATH);
  if (await f.exists()) return (await f.text()).trim();
  const env = process.env.PVE_RO_TOKEN;
  if (env) return env.trim();
  throw new Error(`no PVE token: ${SECRET_PATH} absent and PVE_RO_TOKEN unset`);
}

async function pveGet(endpoint: string, path: string, token: string): Promise<any[]> {
  const res = await fetch(`${endpoint}/api2/json${path}`, {
    headers: { Authorization: `PVEAPIToken=${token}` },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`${path} -> HTTP ${res.status}`);
  return (await res.json()).data ?? [];
}

// Any one node can be down without taking the whole graph with it — a partial topology with
// an explicit warning is far more useful than a 500.
async function tryGet(
  endpoint: string,
  path: string,
  token: string,
  warnings: Warning[],
  code: string,
): Promise<any[]> {
  try {
    return await pveGet(endpoint, path, token);
  } catch (err) {
    warnings.push({ code, detail: `${endpoint}${path}: ${(err as Error).message}` });
    return [];
  }
}

const pct = (used?: number, total?: number) =>
  used != null && total ? Math.round((used / total) * 1000) / 10 : null;

function placement(vmid: number) {
  const g = (layout.guests as Record<string, any>)[String(vmid)];
  if (!g) return { block: "staging", seat: null, target_vmid: null, placed: false };
  return { block: g.block, seat: g.seat, target_vmid: g.target_vmid ?? null, placed: true };
}

async function buildGraph() {
  const warnings: Warning[] = [];
  const token = await readToken();

  // One cluster-wide GET is the enumeration workhorse — not per-guest config, which is 20+
  // round trips for data the resources endpoint already carries.
  const resources = await tryGet(
    NODES[0].endpoint,
    "/cluster/resources",
    token,
    warnings,
    "pve_resources_unreachable",
  );

  // Versions are per-node, so they need a call each. A node being down is a warning, not a
  // failure — the other node's guests are still worth returning.
  const versions: Record<string, string | null> = {};
  await Promise.all(
    NODES.map(async (n) => {
      const v = await tryGet(n.endpoint, "/version", token, warnings, `pve_version_${n.name}`);
      versions[n.name] = (v as any)?.version ?? (v as any)?.release ?? null;
    }),
  );

  const nodes = resources
    .filter((r) => r.type === "node")
    .map((r) => ({
      name: r.node,
      status: r.status,
      cpu_used: r.cpu ?? null,
      cpu_total: r.maxcpu ?? null,
      mem_used: r.mem ?? null,
      mem_total: r.maxmem ?? null,
      mem_pct: pct(r.mem, r.maxmem),
      pve_version: versions[r.node] ?? null,
      // The LAN bridge differs per node and it is a genuine trip hazard, not cosmetic.
      lan_bridge: r.node === "pve01" ? "vmbr1" : r.node === "pve02" ? "vmbr0" : null,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));

  const coverage = layout.iac_coverage as Record<string, string>;

  const guests = resources
    .filter((r) => r.type === "lxc" || r.type === "qemu")
    .map((r) => {
      const vmid = Number(r.vmid);
      return {
        vmid,
        name: r.name ?? null,
        kind: r.type,
        node: r.node,
        status: r.status,
        cores: r.maxcpu ?? null,
        mem_total: r.maxmem ?? null,
        disk_total: r.maxdisk ?? null,
        uptime: r.uptime ?? 0,
        iac: coverage[String(vmid)] ?? "unknown",
        ...placement(vmid),
      };
    })
    .sort((a, b) => a.vmid - b.vmid);

  const storage = resources
    .filter((r) => r.type === "storage")
    .map((r) => ({
      id: r.storage,
      node: r.node,
      status: r.status,
      total: r.maxdisk ?? null,
      used: r.disk ?? null,
      used_pct: pct(r.disk, r.maxdisk),
      shared: Boolean(r.shared),
    }))
    .sort((a, b) => (b.used_pct ?? 0) - (a.used_pct ?? 0));

  // L3's real payoff: cross-node edges that are invisible in any per-host view. These are
  // structural facts about the cluster, not something the API will tell you.
  const storage_edges = [
    {
      from: "pve02:/mnt/nexus-data",
      to: "pve01:106",
      via: "nfs",
      load_bearing: true,
      why: "CT106 (nexus) runs on pve01 but NFS-mounts its blob store from pve02. Break this and docker.pdlab.dev goes with it.",
    },
    {
      from: "pve02:/mnt/backups",
      to: "pve01:pete-backups",
      via: "nfs",
      load_bearing: true,
      why: "The cluster's vzdump target IS pve02's HDD over NFS.",
    },
    {
      from: "pve02:/mnt/shared",
      to: "pve01:pve02-shared",
      via: "nfs",
      load_bearing: false,
      why: "Holds runner-233's rootfs.",
    },
  ];

  // A guest PVE knows about but the layout file does not. This is half of drift; the other
  // half is below and matters just as much.
  for (const g of guests) {
    if (!g.placed) {
      warnings.push({
        code: "unplaced_guest",
        detail: `VMID ${g.vmid} (${g.name}) is live but has no layout entry — parked in staging. Place it deliberately in layout.json.`,
      });
    }
  }

  // Declared but absent. This is the direction that went unnoticed for a month while 113 and
  // 108 sat in the inventory doc as live, long after they were destroyed.
  const liveVmids = new Set(guests.map((g) => g.vmid));
  for (const vmid of Object.keys(layout.guests as Record<string, any>)) {
    if (!liveVmids.has(Number(vmid))) {
      warnings.push({
        code: "declared_not_present",
        detail: `VMID ${vmid} is in layout.json but PVE does not report it. It was destroyed or moved — remove it from the layout.`,
      });
    }
  }

  for (const s of storage) {
    if ((s.used_pct ?? 0) >= 80) {
      warnings.push({
        code: "storage_pressure",
        detail: `${s.node}:${s.id} at ${s.used_pct}% used.`,
      });
    }
  }

  return {
    generated_at: new Date().toISOString(),
    sources: {
      pve: warnings.some((w) => w.code === "pve_resources_unreachable") ? "degraded" : "ok",
      // Enumerating the tailnet needs a Tailscale API key. The key in kv/services/tailscale is
      // a node AUTH key (single-use, for joining) and cannot query the API — so this is
      // deliberately not-configured rather than silently empty.
      tailscale: "not_configured",
    },
    blocks: layout.blocks,
    nodes,
    guests,
    // Declared, never probed: reachability is a health question, not a topology one.
    offcluster: (layout.offcluster as any[]).map((h) => ({ ...h, source: "declared" })),
    storage,
    storage_edges,
    counts: {
      nodes: nodes.length,
      guests: guests.length,
      running: guests.filter((g) => g.status === "running").length,
      stopped: guests.filter((g) => g.status !== "running").length,
      offcluster: (layout.offcluster as any[]).length,
    },
    warnings,
  };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

Bun.serve({
  port: PORT,
  hostname: "0.0.0.0",
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/_/health") return json({ ok: true });
    try {
      return json(await buildGraph());
    } catch (err) {
      return json({ error: (err as Error).message }, 500);
    }
  },
});

console.log(`lab-graph listening on :${PORT}`);
