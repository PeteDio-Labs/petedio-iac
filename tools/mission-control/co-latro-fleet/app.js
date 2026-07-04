"use strict";
/*
  Mission Control — Co-latro fleet activity view (PET-187).

  A read-only static page over the `agent-evals` JSONL eval logs in MinIO. It shows what the
  Co-latro agent fleet is doing across three lanes — Worker / Reviewer / Engine — with a
  Co-latro-only roll-up. NO backend, NO build step, NO framework: plain fetch() + JSONL parse.

  Sources (same-origin behind the Authentik proxy; see README for the host wiring):
    - verdicts.jsonl    Reviewer lane. Schema (PET-135, scripts/reviewer/reviewer-log-verdict.sh):
        {ts,issue,pr,worker_model,harness,reviewer_model,worker_tests:pass|fail,
         claude_verdict:approve|changes,claude_findings:[],pedro_verdict:merge|kickback|"",
         round_trips,tokens,wall_s}
        NOTE: a verdict row carries NO `repo` — only the PR number string + the PET issue key.
        `worker_model`/`harness` describe the PR UNDER REVIEW; `reviewer_model` (PET-199) is
        the model that DECIDED the verdict — the reviewer lane's `model` column shows THAT,
        with the reviewed worker model/harness moved to its tooltip (so it can't misread as
        the reviewer's). Older rows predating PET-199 have no reviewer_model → model shows "—".
    - worker-runs.jsonl Worker lane. Schema (worker-loop.md, scripts/worker/worker-run.sh):
        {ts,issue,repo,branch,pr:int|null,worker_model,harness,tests:pass|fail|skipped|none,
         guard:ok|blocked,tokens,wall_s,head_sha}
        Carries an explicit `repo` — the basis for the Co-latro filter.
    - engine-runs.jsonl Engine lane. No writer exists yet (forward-compat 3rd fleet tier,
        PET-184) → the lane renders an empty-state until the file appears.

  READ-ONLY: this page only ever issues GET requests. It never merges, comments, mutates a
  label, or writes anything anywhere.
*/

// ---- config (the only things you'd tweak) --------------------------------------------
const ALLOWED_USER  = "pedro";              // single-user gate (defense-in-depth; see README)
const DATA_BASE_PROD = "/agent-evals";      // same-origin path the proxy maps to the bucket
const GITHUB_ORG    = "PeteDio-Labs";
const CO_LATRO_REPOS = ["co-latro-backend", "co-latro-frontend"];
const DEFAULT_REPO  = "co-latro-backend";   // for a verdict PR link when the repo can't be joined
const LINEAR_BASE   = "https://linear.app/petedillo/issue/";
const REFRESH_MS    = 20000;                 // auto-refresh cadence (~15–30s per the issue)
const FILES = { verdicts: "verdicts.jsonl", worker: "worker-runs.jsonl", engine: "engine-runs.jsonl",
                events: "events.jsonl" };   // PET-220: the unified lifecycle stream (PET-154)

// ---- PET-254: usage-driven trust fixes -------------------------------------------------
// Probe/test rows (harness dry-runs like PET-9999 / reconciler-probe) pollute the pipeline
// kanban; hide them by default behind a toggle. A real key is PET-<n>; anything else — or an
// explicitly-known probe key — is a test row.
const PROBE_ISSUES  = new Set(["PET-9999"]);                    // known harness probe keys
const isProbeIssue  = (issue) => !!issue && (PROBE_ISSUES.has(issue) || !/^PET-\d{1,4}$/.test(issue));
const SHOW_PROBES_KEY = "fleet.showProbes";                     // localStorage persistence
let SHOW_PROBES = localStorage.getItem(SHOW_PROBES_KEY) === "1";

// GitHub reality check (PET-249's mechanism fix): the page's "pending" piles are inferred
// from verdict gaps, which lied to Pedro once ("we have 7 open prs" — GitHub had 1). We
// cross-check each unresolved PR against api.github.com — public repos, UNauthenticated,
// read-only GETs, so this stays zero-backend/no-secret. Budgeted hard against the 60 req/hr
// anonymous limit: merged/closed are terminal (cached forever in localStorage), open states
// re-check at most every GH_CHECK_MS, and at most GH_MAX_FETCH lookups fire per sweep.
// Any failure (rate-limit, offline) degrades to "unverified" — never blocks the page.
const GH_API        = "https://api.github.com";
// 15 min: N open PRs cost N*4 req/hr — even 10 open PRs stay under the 60/hr anonymous cap.
const GH_CHECK_MS   = 15 * 60 * 1000;        // re-check cadence for still-open PRs
const GH_MAX_FETCH  = 8;                     // per-sweep lookup budget
const GH_BACKOFF_MS = 10 * 60 * 1000;        // after a 403/429, stop calling GitHub for a while
const GH_CACHE_KEY  = "fleet.ghpr";          // localStorage: { "<repo>#<pr>": {state, mergedAt, checkedAt} }

// Data-freshness thresholds ("i don't see an update on the fleet ui"): page-refresh time is
// NOT data age. We stamp the newest telemetry ts in the header and warn when it exceeds this
// (mirror lag or a quiet fleet — the banner says which is more likely).
const DATA_STALE_MS = 2 * 60 * 60 * 1000;    // 2h with no new rows/events -> warn

// ---- dev mode -------------------------------------------------------------------------
// In prod the page lives behind Authentik and reads /agent-evals same-origin. For local dev
// (`?dev=1`, or opened straight from disk) it reads the bundled ./fixtures and skips the
// /whoami gate so the lanes render standalone. This is DEV CONVENIENCE ONLY — the real access
// boundary is Authentik, never this client-side check (README spells this out).
const PARAMS = new URLSearchParams(location.search);
// Dev mode reads local ./fixtures and skips the gate. Honored ONLY on a local origin
// (file:// or localhost) so `?dev` can never bypass anything on the live, Access-gated host.
const DEV = location.protocol === "file:"
  || (PARAMS.has("dev") && (location.hostname === "localhost" || location.hostname === "127.0.0.1"));
const DATA_BASE = DEV ? "./fixtures" : DATA_BASE_PROD;

// ---- tiny helpers ---------------------------------------------------------------------
const $ = (id) => document.getElementById(id);
function esc(s){ return String(s==null?"":s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
const dash = () => `<span class="sub">—</span>`;
function num(v){ return (typeof v === "number" && isFinite(v)) ? v : null; }
function str(v){ return v == null ? "" : String(v); }
function tsVal(iso){ return Date.parse(iso) || 0; }
const byTsDesc = (a,b) => tsVal(b.ts) - tsVal(a.ts);

function ageStr(iso){
  const t = Date.parse(iso); if (!t) return "?";
  let s = Math.max(0, (Date.now() - t) / 1000);
  if (s < 90) return Math.round(s) + "s";
  const m = s / 60; if (m < 90) return Math.round(m) + "m";
  const h = m / 60; if (h < 48) return Math.round(h) + "h";
  return Math.round(h / 24) + "d";
}
function fmtInt(n){ return n == null ? "" : n.toLocaleString(); }
function costTitle(row){
  const parts = [];
  if (row.tokens != null) parts.push(fmtInt(row.tokens) + " tok");
  if (row.wall   != null) parts.push(row.wall + "s");
  if (row.headSha) parts.push(row.headSha);
  return parts.join(" · ");
}

function linearUrl(issue){ return LINEAR_BASE + encodeURIComponent(issue); }
// repo may be org-qualified ("PeteDio-Labs/co-latro-backend", the live worker-runs shape) or
// bare ("co-latro-backend"). repoName() is the trailing name; ghPrUrl only prepends the org
// when the value is bare.
function repoName(repo){ return String(repo || "").split("/").pop(); }
function ghPrUrl(repo, pr){
  const full = String(repo).includes("/") ? repo : `${GITHUB_ORG}/${repo}`;
  return `https://github.com/${full}/pull/${pr}`;
}

// JSONL → rows; one bad line never kills a lane (counted + skipped).
function parseJSONL(text){
  const rows = []; let bad = 0;
  for (const line of text.split("\n")){
    const t = line.trim(); if (!t) continue;
    try { rows.push(JSON.parse(t)); } catch { bad++; }
  }
  return { rows, bad };
}

// ---- fetch one JSONL file, classified so the lane/banner can react -------------------
async function fetchJSONL(name){
  let r;
  try {
    r = await fetch(`${DATA_BASE}/${name}?_=${Date.now()}`, { credentials: "same-origin", cache: "no-store" });
  } catch (e){
    return { rows: [], status: "error", detail: e.message || "network error", bad: 0 };
  }
  if (r.status === 404) return { rows: [], status: "missing", detail: "not found", bad: 0 };
  if (!r.ok)            return { rows: [], status: "error",   detail: `HTTP ${r.status}`, bad: 0 };
  let text = ""; try { text = await r.text(); } catch (e){ return { rows: [], status: "error", detail: "unreadable body", bad: 0 }; }
  const { rows, bad } = parseJSONL(text);
  return { rows, status: rows.length ? "ok" : "empty", detail: "", bad };
}

// ---- identity gate --------------------------------------------------------------------
// In prod: ask the Authentik-fronted proxy who we are. The proxy echoes X-authentik-username
// as JSON at /whoami (a Manual step — see README). Any failure or a non-`pedro` user → locked.
async function getIdentity(){
  if (DEV) return ALLOWED_USER;
  try {
    const r = await fetch("/whoami", { credentials: "same-origin", cache: "no-store" });
    if (!r.ok) return null;
    const j = await r.json();
    return (j && typeof j.username === "string" && j.username) ? j.username : null;
  } catch { return null; }
}

// ---- normalize each source into one row shape ----------------------------------------
// Unified shape so a single renderer drives all three lanes; fields a source lacks stay null
// and render as "—" (the issue's per-lane column set is the union of these).
function normWorker(r){
  return { source:"worker", ts:str(r.ts), issue:str(r.issue), repo:str(r.repo),
    pr:(r.pr==null||r.pr===""?null:r.pr), model:str(r.worker_model), harness:str(r.harness),
    modelTitle:"", tests:str(r.tests)||null, guard:str(r.guard)||null, verdict:null, pedro:null,
    roundTrips:null, findings:null, tokens:num(r.tokens), wall:num(r.wall_s),
    headSha:str(r.head_sha), raw:r };
}
function normVerdict(r){
  // The reviewer lane's `model` is the REVIEWER's model (who decided the verdict), not the
  // worker's — `worker_model`/`harness` describe the PR under review, so they move to the
  // model cell's tooltip (PET-199). reviewer has no patch harness of its own → harness "".
  const workerMH = [str(r.worker_model), str(r.harness)].filter(Boolean).join(" / ");
  return { source:"reviewer", ts:str(r.ts), issue:str(r.issue), repo:str(r.repo||""), // repo normally absent
    pr:(r.pr==null||r.pr===""?null:r.pr), model:str(r.reviewer_model), harness:"",
    modelTitle:workerMH ? `reviewed worker: ${workerMH}` : "",
    tests:str(r.worker_tests)||null, guard:null, verdict:str(r.claude_verdict)||null,
    pedro:str(r.pedro_verdict)||null, roundTrips:num(r.round_trips),
    findings:Array.isArray(r.claude_findings)?r.claude_findings:[], tokens:num(r.tokens),
    wall:num(r.wall_s), headSha:"", raw:r };
}
function normEngine(r){
  // engine-runs schema (PET-184): {ts,issue,repo,branch,pr,engine_model,harness,tests,guard,
  // tokens,wall_s,head_sha} — `guard` carries the gate verdict (green|red). Stay lenient and
  // also accept worker-ish/verdict-ish keys so older/hand-written rows still render.
  return { source:"engine", ts:str(r.ts), issue:str(r.issue), repo:str(r.repo||""),
    pr:(r.pr==null||r.pr===""?null:r.pr), model:str(r.engine_model||r.worker_model||r.model), harness:str(r.harness),
    modelTitle:"", tests:str(r.tests||r.worker_tests)||null, guard:str(r.guard)||null,
    verdict:str(r.claude_verdict||r.verdict)||null, pedro:str(r.pedro_verdict)||null,
    roundTrips:num(r.round_trips), findings:Array.isArray(r.claude_findings)?r.claude_findings:null,
    tokens:num(r.tokens), wall:num(r.wall_s), headSha:str(r.head_sha), raw:r };
}

// ======================================================================================
// PET-220 — LIVE views over the unified events.jsonl lifecycle stream (PET-154).
// The lanes below stay the audit ledger; these three views render "what's happening now".
// events.jsonl schema: {ts, agent:"worker|reviewer|loop|engine", event, issue:"PET-n"|null,
// pr:int|null, detail}. events carry NO repo (unlike runs) — state is inferred from the last
// event's age (no heartbeat; we stay no-backend), so RUNNING really means "last event was a
// start with no matching exit", not a live liveness probe. Noted in the UI + README.
// ======================================================================================
// Status-card order. The Co-latro content fleet is worker/engine/reviewer; the IaC `loop`
// agent isn't instrumented (no emitter) and isn't Co-latro, so it gets no card (PET-221).
// `loop` events are still filtered out of the pipeline below.
const EVENT_AGENTS = ["worker", "engine", "reviewer"];
const RUN_START = new Set(["run_started", "issue_picked"]);      // opens a run
const ALERT_EV  = new Set(["stalled", "escalated_needs_human"]); // needs-a-human events
const PAUSE_EV  = new Set(["cap_paused"]);   // PET-257: quota/off-hours park — NOT an alert
const AGENT_META = {
  worker:   { icon:"🔧", title:"Worker" },
  engine:   { icon:"⚙️", title:"Engine" },
  reviewer: { icon:"🔎", title:"Reviewer" },
};
const STATE_META = {
  running:       { cls:"run",   label:"● running" },
  stalled:       { cls:"alert", label:"■ stalled" },
  "needs-human": { cls:"alert", label:"✋ needs human" },
  paused:        { cls:"pause", label:"⏸ paused" },
  idle:          { cls:"idle",  label:"idle" },
  none:          { cls:"none",  label:"no events" },
};

function normEvent(r){
  return { ts:str(r.ts), agent:str(r.agent), event:str(r.event),
    issue:(r.issue==null||r.issue===""?null:str(r.issue)),
    pr:(r.pr==null||r.pr===""?null:r.pr), detail:str(r.detail), raw:r };
}

// Infer one agent's current state from its events (newest-first). See the block header for the
// RUNNING/STALLED/idle rules — they mirror the issue's spec exactly.
function agentStatus(agent, allEvents, model){
  const evs = allEvents.filter(e => e.agent === agent).sort(byTsDesc);
  if (!evs.length) return { agent, state:"none", model };
  const last = evs[0];
  if (ALERT_EV.has(last.event))
    return { agent, state: last.event === "stalled" ? "stalled" : "needs-human",
      issue:last.issue, pr:last.pr, since:last.ts, detail:last.detail, model };
  // PET-257: a parked engine says so (quota / off-hours / preempt) instead of reading "idle".
  // cap_resumed (and any later event) naturally supersedes it as the newest event.
  if (PAUSE_EV.has(last.event))
    return { agent, state:"paused", issue:last.issue, pr:last.pr, since:last.ts, detail:last.detail, model };
  const lastStart = evs.find(e => RUN_START.has(e.event));
  const lastExit  = evs.find(e => e.event === "run_exited");
  const running   = lastStart && (!lastExit || tsVal(lastStart.ts) >= tsVal(lastExit.ts));
  if (running){
    // current issue = the newest issue_picked inside the open run, else the opening event's issue
    const picked = evs.find(e => e.event === "issue_picked" && (!lastExit || tsVal(e.ts) > tsVal(lastExit.ts)));
    const withPr = evs.find(e => e.pr != null && (!lastExit || tsVal(e.ts) > tsVal(lastExit.ts)));
    return { agent, state:"running", issue:(picked && picked.issue) || lastStart.issue || null,
      pr:(withPr ? withPr.pr : null), since:lastStart.ts, detail:last.detail, model };
  }
  return { agent, state:"idle", issue:last.issue, pr:last.pr, since:last.ts, model };
}

function statusCardHTML(st){
  const m  = AGENT_META[st.agent]  || { icon:"•", title:st.agent };
  const sm = STATE_META[st.state]  || STATE_META.none;
  const rows = [];
  if (st.issue) rows.push(`<div><span class="lk">issue</span> ${petCell({ issue:st.issue })}${st.pr!=null?` <span class="sub">#${esc(String(st.pr))}</span>`:""}</div>`);
  if (st.model) rows.push(`<div><span class="lk">model</span> <span class="val">${esc(st.model)}</span></div>`);
  if (st.since){
    const lbl = st.state === "running" ? "in state" : st.state === "idle" ? "since last activity" : "since";
    rows.push(`<div><span class="lk">${lbl}</span> <span class="val">${esc(ageStr(st.since))}</span></div>`);
  }
  if (st.detail && st.state !== "idle") rows.push(`<div class="sc-detail">${esc(st.detail)}</div>`);
  if (st.state === "none") rows.push(`<div class="sc-detail">no lifecycle events yet</div>`);
  return `<div class="statuscard ${sm.cls}">
    <div class="sc-head">${m.icon} ${esc(m.title)} <span class="sc-badge">${sm.label}</span></div>
    <div class="sc-body">${rows.join("")}</div>
  </div>`;
}

// ---- View 2: per-issue pipeline (Todo -> authoring -> gate -> PR -> review -> merge) ---
const STAGES = ["Todo", "authoring", "gate", "PR", "review", "merge"];
// Join runs + verdicts + events on the PET key. Each issue lands in the FURTHEST stage it has
// reached; stalls/kickbacks/gate-fails colour it. Scoped to Co-latro like the lanes: an issue
// whose repo joins to a non-Co-latro repo is dropped; `loop` (IaC) events are excluded.
function buildPipeline(worker, engine, reviewer, events, issueMap){
  const issues = new Map();
  const get = (issue) => {
    if (!issues.has(issue)) issues.set(issue, { issue, stageIdx:0, latestTs:0, latestIso:"",
      pr:null, stalled:false, changes:false, gateFail:false, note:"" });
    return issues.get(issue);
  };
  const bump  = (a, i) => { if (i > a.stageIdx) a.stageIdx = i; };
  const touch = (a, ts) => { const t = tsVal(ts); if (t > a.latestTs){ a.latestTs = t; a.latestIso = ts; } };

  for (const r of worker.concat(engine)){
    if (!r.issue) continue;
    const a = get(r.issue); bump(a, 1);
    if (r.guard){ bump(a, 2); if (r.guard === "red" || r.guard === "blocked") a.gateFail = true; }
    if (r.pr != null){ bump(a, 3); if (a.pr == null) a.pr = r.pr; }
    touch(a, r.ts);
  }
  for (const v of reviewer){
    if (!v.issue) continue;
    const a = get(v.issue);
    if (v.pr != null){ bump(a, 3); if (a.pr == null) a.pr = v.pr; }
    if (v.verdict){ bump(a, 4); if (v.verdict === "changes") a.changes = true; }
    if (v.pedro === "merge")    bump(a, 5);
    if (v.pedro === "kickback") a.changes = true;
    touch(a, v.ts);
  }
  for (const e of events){
    if (!e.issue || e.agent === "loop") continue;                  // loop = IaC, off the Co-latro board
    const rep = issueMap.get(e.issue);
    if (rep !== undefined && !isCoLatroRepo(rep)) continue;         // resolvable, non-Co-latro -> drop
    const a = get(e.issue);
    if (RUN_START.has(e.event)) bump(a, 1);
    if (e.event === "pr_opened" || e.pr != null){ bump(a, 3); if (a.pr == null) a.pr = e.pr; }
    if (e.event === "verdict_posted") bump(a, 4);
    if (e.event === "changes_requested"){ bump(a, 4); a.changes = true; }
    if (ALERT_EV.has(e.event)){ a.stalled = true; a.note = e.detail || e.event; }
    touch(a, e.ts);
  }
  // Drop issues that only ever came from a non-Co-latro run (defensive; runs are already filtered).
  const out = [...issues.values()].filter(a => { const r = issueMap.get(a.issue); return r === undefined || isCoLatroRepo(r); });
  for (const a of out){
    if (a.stalled)            a.status = "stalled";
    else if (a.stageIdx >= 5) a.status = "merged";
    else if (a.changes || a.gateFail) a.status = "attention";
    else                      a.status = "active";
  }
  return out.sort((x, y) => y.latestTs - x.latestTs);
}

function pipeChipHTML(a){
  const cls = { merged:"green", stalled:"alert", attention:"yellow", active:"blue" }[a.status] || "blue";
  const pr  = a.pr != null ? ` <span class="sub">#${esc(String(a.pr))}</span>` : "";
  const tip = (a.note ? a.note + " · " : "") + "updated " + ageStr(a.latestIso);
  return `<a class="kchip ${cls}" href="${esc(linearUrl(a.issue))}" target="_blank" rel="noopener" title="${esc(tip)}">${esc(a.issue)}${pr}</a>`;
}
function pipelineHTML(items){
  if (!items.length) return `<div class="empty">No active issues in <code>events.jsonl</code> yet.</div>`;
  const cols = STAGES.map((s, i) => {
    const here  = items.filter(a => a.stageIdx === i);
    const chips = here.map(pipeChipHTML).join("") || `<div class="kempty">—</div>`;
    return `<div class="kcol"><div class="khead">${esc(s)} <span class="sub">${here.length}</span></div>
      <div class="kbody">${chips}</div></div>`;
  }).join("");
  return `<div class="kanban">${cols}</div>`;
}

// ---- View 3: pass-rate + trend sparklines (bucket ts by day) --------------------------
const dayKey = (iso) => str(iso).slice(0, 10);                     // YYYY-MM-DD
function dailyRate(rows, okFn, inFn){                              // -> [{d, rate, ok, tot}]
  const b = new Map();
  for (const r of rows){ if (!inFn(r)) continue; const k = dayKey(r.ts);
    const c = b.get(k) || { ok:0, tot:0 }; c.tot++; if (okFn(r)) c.ok++; b.set(k, c); }
  return [...b.keys()].sort().map(d => ({ d, rate:b.get(d).ok / b.get(d).tot, ok:b.get(d).ok, tot:b.get(d).tot }));
}
function dailySum(rows, valFn){                                    // -> [{d, val}]
  const b = new Map();
  for (const r of rows){ const v = valFn(r); if (v == null) continue; const k = dayKey(r.ts); b.set(k, (b.get(k) || 0) + v); }
  return [...b.keys()].sort().map(d => ({ d, val:b.get(d) }));
}
function sparkSVG(values, max){
  if (!values.length) return "";
  const W = 120, H = 26, P = 2, mx = (max != null ? max : Math.max(...values)) || 1;
  const step = values.length > 1 ? (W - 2 * P) / (values.length - 1) : 0;
  const pts = values.map((v, i) => `${(P + i * step).toFixed(1)},${(H - P - Math.max(0, v) / mx * (H - 2 * P)).toFixed(1)}`).join(" ");
  const dots = values.length === 1 ? `<circle cx="${W/2}" cy="${(H - P - values[0] / mx * (H - 2*P)).toFixed(1)}" r="2" fill="var(--blue)"/>` : "";
  return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    <polyline points="${pts}" fill="none" stroke="var(--blue)" stroke-width="1.5" vector-effect="non-scaling-stroke"/>${dots}</svg>`;
}
function rateCard(title, series){
  const tot = series.reduce((s, p) => s + p.tot, 0), ok = series.reduce((s, p) => s + p.ok, 0);
  const pct = tot ? Math.round(100 * ok / tot) : null;
  return `<div class="stat"><div class="k">${esc(title)}</div>
    <div class="v">${pct == null ? "—" : pct + "%"}</div>
    ${sparkSVG(series.map(p => p.rate), 1)}
    <div class="d">${tot ? `${ok}/${tot} · ${series.length}d` : "no data"}</div></div>`;
}
function sumCard(title, series){
  if (!series.length) return statCard(title, "—", "no data");
  const total = series.reduce((s, p) => s + p.val, 0);
  return `<div class="stat"><div class="k">${esc(title)}</div>
    <div class="v">${fmtInt(Math.round(total / series.length))}</div>
    ${sparkSVG(series.map(p => p.val))}
    <div class="d">avg/day · ${series.length}d</div></div>`;
}
function trendsHTML(worker, reviewer, engine){
  const wr = dailyRate(worker,   r => r.tests === "pass",   r => r.tests === "pass" || r.tests === "fail");
  const er = dailyRate(engine,   r => r.guard === "green",  r => r.guard === "green" || r.guard === "red");
  const rr = dailyRate(reviewer, r => r.verdict === "approve", r => r.verdict === "approve" || r.verdict === "changes");
  const et = dailySum(engine,    r => r.tokens);
  const dist = {};
  for (const r of reviewer) if (r.roundTrips != null) dist[r.roundTrips] = (dist[r.roundTrips] || 0) + 1;
  return `<div class="rollup">
    ${rateCard("worker pass-rate", wr)}
    ${rateCard("engine gate-green", er)}
    ${rateCard("reviewer approve", rr)}
    ${sumCard("engine tokens/day", et)}
    ${barsCard(dist)}
  </div>`;
}

// ---- the Co-latro filter (made obvious, per the issue) -------------------------------
const isCoLatroRepo = (repo) => CO_LATRO_REPOS.includes(repoName(repo));

// Worker/engine rows carry `repo`, so we map PET-issue → repo from them. Reviewer verdicts
// have no `repo`, so we decide their Co-latro membership by joining on that PET key. A
// co-latro repo wins if an issue somehow appears under more than one repo.
function buildIssueRepoMap(workerRows, engineRows){
  const map = new Map();
  for (const r of workerRows.concat(engineRows)){
    if (!r.repo || !r.issue) continue;
    const cur = map.get(r.issue);
    if (cur === undefined || (!isCoLatroRepo(cur) && isCoLatroRepo(r.repo))) map.set(r.issue, r.repo);
  }
  return map;
}
// Keep a verdict only if its repo (its own, or joined by issue) is Co-latro. Anything we
// can't confirm is hidden — but COUNTED and LISTED, never silently dropped (surfaced as an
// expandable banner: Pedro asked "what does this mean" twice, so the banner now shows the
// rows and how to fix them instead of a bare count — PET-254).
function filterVerdicts(verdictRows, issueMap){
  const kept = [], hiddenRows = [];
  for (const r of verdictRows){
    const repo = r.repo || issueMap.get(r.issue) || "";
    if (isCoLatroRepo(repo)){ r.repo = repo; kept.push(r); }   // stamp the resolved repo for PR links
    else hiddenRows.push(r);
  }
  return { kept, hidden: hiddenRows.length, hiddenRows };
}

// ======================================================================================
// PET-254 — PR reality panel ("needs Pedro") + GitHub cross-check.
// The verdict-gap inference lied once (PET-249): merged-but-unstamped PRs read "pending"
// forever. This joins runs+verdicts per PR and, where possible, verifies against live
// GitHub state, splitting the pile into what Pedro actually has to do:
//   awaiting-review   run opened a PR, no reviewer verdict yet
//   awaiting-decision reviewer verdict logged, pedro_verdict still ""
//   unstamped         GitHub says MERGED but pedro_verdict was never stamped -> stamp it
// Rows whose GitHub state can't be confirmed stay listed as "unverified", never hidden.
// ======================================================================================
let ghCache = {};
try { ghCache = JSON.parse(localStorage.getItem(GH_CACHE_KEY) || "{}") || {}; } catch { ghCache = {}; }
function ghCacheSave(){ try { localStorage.setItem(GH_CACHE_KEY, JSON.stringify(ghCache)); } catch {} }
const ghKey = (repo, pr) => `${repoName(repo)}#${pr}`;

// DEV: fixtures/gh-prs.json maps "repo#pr" -> {state:"open"|"merged"|"closed"} so the panel
// (incl. the unstamped bucket) is exercisable offline with no GitHub calls.
let devGhStates = null;
async function ghStateDev(repo, pr){
  if (devGhStates === null){
    try { const r = await fetch(`${DATA_BASE}/gh-prs.json?_=${Date.now()}`, { cache:"no-store" });
          devGhStates = r.ok ? await r.json() : {}; }
    catch { devGhStates = {}; }
  }
  const hit = devGhStates[ghKey(repo, pr)];
  return hit ? { state: hit.state, mergedAt: hit.mergedAt || null } : null;
}

// Resolve one PR's live state, cache-first. Returns {state:"open|merged|closed", checkedAt}
// or null (unverified). Terminal states never refetch; open states refetch after GH_CHECK_MS;
// a rate-limit response mutes ALL GitHub calls for GH_BACKOFF_MS (don't hammer a 403).
let ghBackoffUntil = 0;
async function ghPrState(repo, pr, budget){
  const key = ghKey(repo, pr);
  const hit = ghCache[key];
  if (hit && (hit.state === "merged" || hit.state === "closed")) return hit;
  if (hit && Date.now() - hit.checkedAt < GH_CHECK_MS) return hit;
  if (DEV){
    const d = await ghStateDev(repo, pr);
    if (!d) return hit || null;
    ghCache[key] = { ...d, checkedAt: Date.now() }; ghCacheSave(); return ghCache[key];
  }
  if (Date.now() < ghBackoffUntil) return hit || null;   // muted after a rate-limit
  if (budget.n <= 0) return hit || null;                 // out of per-sweep budget -> best effort
  budget.n--;
  try {
    const full = String(repo).includes("/") ? repo : `${GITHUB_ORG}/${repoName(repo)}`;
    const r = await fetch(`${GH_API}/repos/${full}/pulls/${pr}`, { cache:"no-store" });
    if (r.status === 403 || r.status === 429){            // rate-limited -> back off, unverified
      ghBackoffUntil = Date.now() + GH_BACKOFF_MS;
      return hit || null;
    }
    if (r.status === 404) return hit || null;             // private/missing -> unverified
    if (!r.ok) return hit || null;
    const j = await r.json();
    const state = j.merged_at ? "merged" : (j.state === "open" ? "open" : "closed");
    ghCache[key] = { state, mergedAt: j.merged_at || null, checkedAt: Date.now() };
    ghCacheSave();
    return ghCache[key];
  } catch { return hit || null; }
}

// Join everything the telemetry knows per (repo, pr).
function buildPrRecords(worker, engine, reviewer){
  const recs = new Map();
  const get = (repo, pr) => {
    const k = ghKey(repo, pr);
    if (!recs.has(k)) recs.set(k, { repo, pr, issue:null, lastTs:"", verdict:null, pedro:null, findings:0 });
    return recs.get(k);
  };
  for (const r of worker.concat(engine)){
    if (r.pr == null || !r.repo) continue;
    const a = get(r.repo, r.pr);
    if (!a.issue) a.issue = r.issue || null;
    if (tsVal(r.ts) > tsVal(a.lastTs)) a.lastTs = r.ts;
  }
  // Ascending ts so the LATEST verdict row decides the PR's state — a round-2 re-review
  // resets pedro to pending even if round 1 was a kickback.
  for (const v of reviewer.slice().sort((a, b) => tsVal(a.ts) - tsVal(b.ts))){
    if (v.pr == null) continue;
    const a = get(v.repo || DEFAULT_REPO, v.pr);
    if (!a.issue) a.issue = v.issue || null;
    if (v.verdict) a.verdict = v.verdict;
    a.pedro    = v.pedro || null;
    a.findings = (v.findings && v.findings.length) || 0;
    if (tsVal(v.ts) > tsVal(a.lastTs)) a.lastTs = v.ts;
  }
  return [...recs.values()];
}

// Classify each PR record against telemetry + (best-effort) GitHub truth.
async function buildPrReality(worker, engine, reviewer){
  const budget = { n: GH_MAX_FETCH };
  const recs = buildPrRecords(worker, engine, reviewer)
    .filter(a => !a.pedro)                     // stamped rows are settled — nothing for Pedro
    .sort((x, y) => tsVal(y.lastTs) - tsVal(x.lastTs));
  const out = [];
  for (const a of recs){
    const gh = await ghPrState(a.repo, a.pr, budget);
    const ghState = gh ? gh.state : null;
    if (ghState === "closed"){ continue; }     // closed-unmerged (kickback path) — settled
    let bucket;
    if (ghState === "merged")      bucket = "unstamped";
    else if (a.verdict)            bucket = "decision";
    else                           bucket = "review";
    out.push({ ...a, ghState, bucket });
  }
  return out;
}

const NP_META = {
  unstamped: { cls:"yellow", label:"merged — stamp verdict",
    tip:(a)=>`GitHub says MERGED but pedro_verdict was never stamped — the row reads "pending" forever (PET-249).\nFix: scripts/reviewer/reviewer-stamp-pedro-verdict.sh --issue ${a.issue||"PET-?"} --pr ${a.pr} --verdict merge` },
  decision:  { cls:"blue",  label:"awaiting your decision",
    tip:()=>"Reviewer verdict logged; merge or kick back, then stamp pedro_verdict." },
  review:    { cls:"muted", label:"awaiting review",
    tip:()=>"PR opened by a run; no reviewer verdict yet. If this sits for hours, check the reviewer loop." },
};
function needsPedroHTML(items){
  if (!items.length)
    return `<div class="empty">Nothing needs you — every fleet PR is reviewed, decided, and stamped.</div>`;
  const rows = items.map(a => {
    const m = NP_META[a.bucket];
    const ver = a.ghState ? `<span class="pill ${a.ghState==="merged"?"green":"blue"}" title="live GitHub state">${esc("gh: "+a.ghState)}</span>`
                          : `<span class="pill muted" title="GitHub state not confirmed (rate-limit/offline) — inferred from telemetry only">gh: unverified</span>`;
    return `<tr>
      <td>${prCell(a)}</td>
      <td class="repo">${esc(repoName(a.repo))}</td>
      <td>${petCell(a)}</td>
      <td><span class="pill ${m.cls}" title="${esc(m.tip(a))}">${esc(m.label)}</span>${a.verdict?` ${verdictPill(a.verdict)}`:""}${a.findings?` <span class="pill yellow">${a.findings} finding${a.findings>1?"s":""}</span>`:""}</td>
      <td>${ver}</td>
      <td class="repo">${esc(ageStr(a.lastTs))}</td>
    </tr>`;
  }).join("");
  return `<table><thead><tr>
    <th>PR</th><th>repo</th><th>PET</th><th>state</th><th>github</th><th>age</th>
  </tr></thead><tbody>${rows}</tbody></table>`;
}

// ---- pills / cells --------------------------------------------------------------------
function pill(cls, text, title){ return `<span class="pill ${cls}"${title?` title="${esc(title)}"`:""}>${esc(text)}</span>`; }
function testsPill(v){
  const m = { pass:["green","✓ pass"], fail:["red","✗ fail"], skipped:["muted","skipped"], none:["muted","none"] };
  const [c,t] = m[v] || ["muted", v]; return pill(c, t);
}
function verdictPill(v){
  const m = { approve:["green","✓ approve"], changes:["yellow","● changes"] };
  const [c,t] = m[v] || ["muted", v]; return pill(c, t);
}
function pedroPill(v){
  const m = { merge:["green","merge"], kickback:["red","kickback"] };
  const [c,t] = m[v] || ["muted", v]; return pill(c, t);
}
function guardPill(v){ return v === "blocked" ? pill("red","guard:blocked") : pill("muted","guard:ok"); }
function findingsTag(row){
  if (!row.findings || !row.findings.length) return "";
  return " " + pill("yellow", row.findings.length + " finding" + (row.findings.length>1?"s":""), row.findings.join("\n"));
}
function prCell(row){
  if (row.pr == null || row.pr === "") return dash();
  const repo = (row.repo && isCoLatroRepo(row.repo)) ? row.repo : (row.repo || DEFAULT_REPO);
  return `<a href="${esc(ghPrUrl(repo, row.pr))}" target="_blank" rel="noopener">#${esc(String(row.pr))}</a>`;
}
function petCell(row){
  return row.issue ? `<a href="${esc(linearUrl(row.issue))}" target="_blank" rel="noopener">${esc(row.issue)}</a>` : dash();
}
function testsCell(row){
  if (!row.tests && row.guard == null) return dash();
  const t = row.tests ? testsPill(row.tests) : "";
  const g = (row.source === "worker" && row.guard) ? " " + guardPill(row.guard) : "";
  return t + g || dash();
}

// ---- rendering ------------------------------------------------------------------------
function rowHTML(row){
  const verdict = row.verdict ? verdictPill(row.verdict) + findingsTag(row) : dash();
  const pedro   = row.pedro   ? pedroPill(row.pedro) : dash();
  const rt      = row.roundTrips == null ? dash() : esc(String(row.roundTrips));
  // model cell shows the lane agent's own model; row.modelTitle (e.g. the worker a verdict
  // reviewed) rides along as a tooltip so it's visible without misreading as the lane agent's.
  const tt      = row.modelTitle ? ` title="${esc(row.modelTitle)}"` : "";
  const mh      = row.model
    ? `<span${tt}>${esc(row.model)}${row.harness?` <span class="sub">/ ${esc(row.harness)}</span>`:""}</span>`
    : (row.modelTitle ? `<span class="sub"${tt}>—</span>` : dash());
  return `<tr>
    <td>${petCell(row)}</td>
    <td class="repo">${row.repo?esc(repoName(row.repo)):dash()}</td>
    <td>${prCell(row)}</td>
    <td>${mh}</td>
    <td>${testsCell(row)}</td>
    <td>${verdict}</td>
    <td>${pedro}</td>
    <td>${rt}</td>
    <td class="repo"><span title="${esc(costTitle(row))}">${esc(ageStr(row.ts))}</span></td>
  </tr>`;
}
function table(rows){
  return `<table><thead><tr>
    <th>PET</th><th>repo</th><th>PR</th><th>model / harness</th><th>tests</th>
    <th>verdict</th><th>pedro</th><th>RT</th><th>age</th>
  </tr></thead><tbody>${rows.map(rowHTML).join("")}</tbody></table>`;
}
function latestCard(row){
  if (!row) return `<div class="latest none">No runs yet.</div>`;
  const bit = (k,v) => `<span><span class="lk">${k}</span> ${v}</span>`;
  const out = [ bit("issue", petCell(row)), bit("pr", prCell(row)) ];
  if (row.model)            out.push(bit("model", `<span${row.modelTitle?` title="${esc(row.modelTitle)}"`:""}>${esc(row.model)}${row.harness?` / ${esc(row.harness)}`:""}</span>`));
  else if (row.modelTitle)  out.push(bit("model", `<span class="sub" title="${esc(row.modelTitle)}">—</span>`));
  if (row.tests || row.guard!=null) out.push(bit("tests", testsCell(row)));
  if (row.verdict)          out.push(bit("verdict", verdictPill(row.verdict) + findingsTag(row)));
  if (row.pedro)            out.push(bit("pedro", pedroPill(row.pedro)));
  if (row.roundTrips!=null) out.push(bit("round-trips", esc(String(row.roundTrips))));
  out.push(bit("age", esc(ageStr(row.ts))));
  return `<div class="latest">${out.join("")}</div>`;
}
function laneHTML(cfg, rows, fileState){
  const sorted = rows.slice().sort(byTsDesc);
  let body;
  if (fileState.status === "missing")     body = `<div class="empty">No <code>${esc(cfg.file)}</code> yet — lane idle.</div>`;
  else if (fileState.status === "error")  body = `<div class="empty">Could not load <code>${esc(cfg.file)}</code> — ${esc(fileState.detail)}.</div>`;
  else if (!sorted.length)                body = `<div class="empty">No Co-latro runs in <code>${esc(cfg.file)}</code> yet.</div>`;
  else body = latestCard(sorted[0]) + `<details class="hist" open><summary>history — ${sorted.length} run(s), newest first</summary>${table(sorted)}</details>`;
  return `<section class="lane">
    <h3>${cfg.icon} ${esc(cfg.title)} <span class="sub">(${sorted.length})</span></h3>
    <div class="lanesub">${esc(cfg.sub)} · <code>${esc(cfg.file)}</code></div>
    ${body}
  </section>`;
}

function statCard(k, v, d){ return `<div class="stat"><div class="k">${esc(k)}</div><div class="v">${v}</div><div class="d">${d||""}</div></div>`; }
function barsCard(dist){
  const keys = Object.keys(dist).map(Number).sort((a,b)=>a-b);
  if (!keys.length) return statCard("round-trips", "—", "no reviewer rows");
  const max = Math.max(...keys.map(k => dist[k]));
  const bars = keys.map(k => `<div class="b" style="height:${Math.round(100*dist[k]/max)}%" title="${k} round-trip(s): ${dist[k]}"></div>`).join("");
  const lbls = keys.map(k => `<span>${k}</span>`).join("");
  return `<div class="stat"><div class="k">round-trip distribution</div>
    <div class="bars">${bars}</div><div class="bars lbl">${lbls}</div></div>`;
}
function rollupHTML(worker, reviewer, engine){
  const tested = worker.filter(r => r.tests === "pass" || r.tests === "fail");
  const wPass  = tested.filter(r => r.tests === "pass").length;
  const rate   = tested.length ? Math.round(100 * wPass / tested.length) : null;
  const wOther = worker.length - tested.length;
  const approve  = reviewer.filter(r => r.verdict === "approve").length;
  const changes  = reviewer.filter(r => r.verdict === "changes").length;
  const merge    = reviewer.filter(r => r.pedro === "merge").length;
  const kickback = reviewer.filter(r => r.pedro === "kickback").length;
  const pending  = reviewer.filter(r => r.verdict && !r.pedro).length;
  const dist = {};
  for (const r of reviewer) if (r.roundTrips != null) dist[r.roundTrips] = (dist[r.roundTrips]||0) + 1;

  return `<div class="rollup">
    ${statCard("worker runs", worker.length, `${wPass} pass · ${tested.length - wPass} fail · ${wOther} other`)}
    ${statCard("worker success", rate == null ? "—" : rate + "%", rate == null ? "no pass/fail rows" : `${wPass}/${tested.length} (pass/fail)`)}
    ${statCard("reviewer verdicts", reviewer.length, `<span class="pill green">${approve} approve</span> <span class="pill yellow">${changes} changes</span>`)}
    ${statCard("pedro", merge + kickback, `<span class="pill green">${merge} merge</span> <span class="pill red">${kickback} kickback</span>${pending?` <span class="pill muted">${pending} pending</span>`:""}`)}
    ${statCard("engine runs", engine.length, engine.length ? "" : "forward-compat — idle")}
    ${barsCard(dist)}
  </div>`;
}

// ---- banners --------------------------------------------------------------------------
function renderBanners(states){
  const b = [];
  if (DEV) b.push(["warn", `<strong>DEV MODE</strong> — reading local <code>./fixtures</code> and bypassing the <code>/whoami</code> gate. This is dev convenience only; Authentik is the real access boundary.`]);
  const fileLabel = { v:"verdicts.jsonl", w:"worker-runs.jsonl", e:"engine-runs.jsonl", ev:"events.jsonl" };
  for (const key of ["v","w","e","ev"]){
    const st = states[key];
    if (st.status === "error") b.push(["err", `Could not load <code>${fileLabel[key]}</code> — ${esc(st.detail)}.`]);
    if (st.bad > 0)            b.push(["warn", `${st.bad} malformed line(s) skipped in <code>${fileLabel[key]}</code>.`]);
  }
  // Freshness ("i don't see an update on the fleet ui"): the page refreshing is not the data
  // moving. If the newest telemetry row is old, say so — and say which failure it smells like.
  if (states.newestTs && Date.now() - tsVal(states.newestTs) > DATA_STALE_MS){
    const age = ageStr(states.newestTs);
    b.push(["warn", `No new telemetry for <strong>${esc(age)}</strong> (newest row ${esc(new Date(tsVal(states.newestTs)).toLocaleString())}). Either the fleet is idle, or the <code>mc mirror</code> on 242 / the loops are stuck — <code>systemctl list-timers worker-loop.timer engine-loop.timer reviewer-loop.timer</code> on 242 tells you which.`]);
  }
  // Hidden verdicts, now expandable: Pedro asked "what does this mean" twice. Show the rows,
  // why the join failed, and the fix — never a bare count (PET-254).
  if (states.hidden > 0){
    const rows = (states.hiddenRows || []).map(r => `<tr>
      <td>${petCell(r)}</td><td>${r.pr!=null?esc("#"+r.pr):"—"}</td>
      <td>${r.verdict?esc(r.verdict):"—"}</td><td>${esc(ageStr(r.ts))}</td></tr>`).join("");
    b.push(["info", `<details><summary>${states.hidden} reviewer verdict(s) hidden — no worker/engine run ties the PET key to a Co-latro repo, so the Co-latro filter can't confirm it. Click for the rows + fix.</summary>
      <table class="mini"><thead><tr><th>PET</th><th>PR</th><th>verdict</th><th>age</th></tr></thead><tbody>${rows}</tbody></table>
      <div class="sub" style="margin-top:6px">Usually a pre-harness or non-Co-latro row. If it IS Co-latro, stamp <code>repo</code> onto the verdict row in <code>agent-evals/verdicts.jsonl</code> (optional field — the filter honors it) and it will surface here.</div>
    </details>`]);
  }
  $("banners").innerHTML = b.map(([k,m]) => `<div class="banner ${k}">${m}</div>`).join("");
}

// ---- locked state ---------------------------------------------------------------------
function renderLocked(user){
  $("content").style.display = "none";
  $("banners").innerHTML = "";
  const who = user ? ` You are signed in as <code>${esc(user)}</code>.` : " Your identity could not be confirmed.";
  $("gate").style.display = "";
  $("gate").innerHTML = `<div class="lock">
    <h2>🔒 Not authorized</h2>
    <p>This view is restricted to <code>${esc(ALLOWED_USER)}</code>.${who}</p>
    <p>No fleet data has been loaded. Access is enforced upstream by Authentik — this page only reflects it.</p>
    <p><button id="retry">Retry</button></p>
  </div>`;
  $("retry").addEventListener("click", load);
  setStatus("locked");
}

// ---- main load (gate → fetch → filter → render) --------------------------------------
function setStatus(t){ $("status").textContent = t; }
// "updated" = when the PAGE fetched; "data as of" = the newest telemetry row. Conflating the
// two is exactly what made "i don't see an update on the fleet ui" undiagnosable (PET-254).
function setUpdated(newestTs){
  const dataBit = newestTs ? ` · data as of ${new Date(tsVal(newestTs)).toLocaleTimeString()} (${ageStr(newestTs)} ago)` : "";
  $("updated").textContent = "· page updated " + new Date().toLocaleTimeString() + dataBit;
}

async function load(){
  const user = await getIdentity();
  if (user !== ALLOWED_USER){ renderLocked(user); return; }   // load NO fleet data

  $("gate").style.display = "none";
  $("content").style.display = "";
  setStatus("loading…");

  const [v, w, e, ev] = await Promise.all([
    fetchJSONL(FILES.verdicts), fetchJSONL(FILES.worker), fetchJSONL(FILES.engine), fetchJSONL(FILES.events),
  ]);

  // Probe hygiene (PET-254): harness dry-run rows (PET-9999 / malformed keys) are test data,
  // not fleet activity — filtered everywhere unless the "show test rows" toggle is on.
  const notProbe   = (r) => SHOW_PROBES || !isProbeIssue(r.issue);
  const workerAll  = w.rows.map(normWorker).filter(notProbe);
  const engineAll  = e.rows.map(normEngine).filter(notProbe);
  const verdictAll = v.rows.map(normVerdict).filter(notProbe);
  const eventsAll  = ev.rows.map(normEvent).filter(notProbe);   // fleet-wide: events carry no repo

  const issueMap = buildIssueRepoMap(workerAll, engineAll);
  const worker   = workerAll.filter(r => isCoLatroRepo(r.repo));
  const engine   = engineAll.filter(r => isCoLatroRepo(r.repo));
  const { kept: reviewer, hidden, hiddenRows } = filterVerdicts(verdictAll, issueMap);

  // Newest telemetry ts across every source — the page's honest "data as of".
  const newestTs = [workerAll, engineAll, verdictAll, eventsAll].flat()
    .reduce((acc, r) => tsVal(r.ts) > tsVal(acc) ? r.ts : acc, "");

  renderBanners({ v, w, e, ev, hidden, hiddenRows, newestTs });

  // ---- PET-220 live views (events.jsonl) ----------------------------------------------
  const latestModel = (rows) => { const s = rows.slice().sort(byTsDesc); for (const r of s) if (r.model) return r.model; return ""; };
  const modelByAgent = { worker:latestModel(worker), engine:latestModel(engine), reviewer:latestModel(reviewer), loop:"" };
  $("status-cards").innerHTML = EVENT_AGENTS.map(a => statusCardHTML(agentStatus(a, eventsAll, modelByAgent[a]))).join("");
  $("pipeline").innerHTML     = pipelineHTML(buildPipeline(worker, engine, reviewer, eventsAll, issueMap));
  $("trends").innerHTML       = trendsHTML(worker, reviewer, engine);

  // ---- PET-254: needs-Pedro panel (async — GitHub lookups may take a beat; the rest of
  // the page never waits on it, and a failed sweep just leaves rows "gh: unverified").
  $("needs-pedro").innerHTML = `<div class="empty">checking…</div>`;
  buildPrReality(worker, engine, reviewer)
    .then(items => { $("needs-pedro").innerHTML = needsPedroHTML(items); })
    .catch(()   => { $("needs-pedro").innerHTML = needsPedroHTML([]); });

  // ---- ledger (unchanged: roll-up + the three history lanes) --------------------------
  $("rollup").innerHTML = rollupHTML(worker, reviewer, engine);
  $("lanes").innerHTML =
      laneHTML({ key:"worker",   title:"Worker",   icon:"🔧", sub:"authors green PRs",      file:FILES.worker },   worker,   w)
    + laneHTML({ key:"reviewer", title:"Reviewer", icon:"🔎", sub:"approve / request-changes", file:FILES.verdicts }, reviewer, v)
    + laneHTML({ key:"engine",   title:"Engine",   icon:"⚙️", sub:"3rd fleet tier (PET-184)", file:FILES.engine },   engine,   e);

  setUpdated(newestTs);
  const total = worker.length + reviewer.length + engine.length;
  setStatus(`${total} Co-latro run(s) · ${reviewer.length} verdict(s) · ${eventsAll.length} event(s)`);
}

// ---- auto-refresh + wiring ------------------------------------------------------------
let timer = null;
function startTimer(){ stopTimer(); timer = setInterval(load, REFRESH_MS); refreshDot(true); }
function stopTimer(){ if (timer){ clearInterval(timer); timer = null; } refreshDot(false); }
function refreshDot(on){ const d = $("autodot"); if (d) d.className = on ? "dot" : "dot off"; }

document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopTimer();
  else { load(); startTimer(); }
});

window.addEventListener("DOMContentLoaded", () => {
  if (DEV) $("devbadge").style.display = "";
  $("refresh").addEventListener("click", load);
  $("autohz").textContent = (REFRESH_MS / 1000) + "s";
  const probes = $("showprobes");
  probes.checked = SHOW_PROBES;
  probes.addEventListener("change", () => {
    SHOW_PROBES = probes.checked;
    localStorage.setItem(SHOW_PROBES_KEY, SHOW_PROBES ? "1" : "0");
    load();
  });
  load();
  startTimer();
});
