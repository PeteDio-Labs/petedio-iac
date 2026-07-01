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
const FILES = { verdicts: "verdicts.jsonl", worker: "worker-runs.jsonl", engine: "engine-runs.jsonl" };

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
// can't confirm is hidden — but COUNTED, never silently dropped (surfaced as a banner).
function filterVerdicts(verdictRows, issueMap){
  const kept = []; let hidden = 0;
  for (const r of verdictRows){
    const repo = r.repo || issueMap.get(r.issue) || "";
    if (isCoLatroRepo(repo)){ r.repo = repo; kept.push(r); }   // stamp the resolved repo for PR links
    else hidden++;
  }
  return { kept, hidden };
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
  const fileLabel = { v:"verdicts.jsonl", w:"worker-runs.jsonl", e:"engine-runs.jsonl" };
  for (const key of ["v","w","e"]){
    const st = states[key];
    if (st.status === "error") b.push(["err", `Could not load <code>${fileLabel[key]}</code> — ${esc(st.detail)}.`]);
    if (st.bad > 0)            b.push(["warn", `${st.bad} malformed line(s) skipped in <code>${fileLabel[key]}</code>.`]);
  }
  if (states.hidden > 0) b.push(["info", `${states.hidden} reviewer verdict(s) hidden — couldn't confirm a Co-latro repo (no matching worker run for the issue).`]);
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
function setUpdated(){ $("updated").textContent = "· updated " + new Date().toLocaleTimeString(); }

async function load(){
  const user = await getIdentity();
  if (user !== ALLOWED_USER){ renderLocked(user); return; }   // load NO fleet data

  $("gate").style.display = "none";
  $("content").style.display = "";
  setStatus("loading…");

  const [v, w, e] = await Promise.all([
    fetchJSONL(FILES.verdicts), fetchJSONL(FILES.worker), fetchJSONL(FILES.engine),
  ]);

  const workerAll  = w.rows.map(normWorker);
  const engineAll  = e.rows.map(normEngine);
  const verdictAll = v.rows.map(normVerdict);

  const issueMap = buildIssueRepoMap(workerAll, engineAll);
  const worker   = workerAll.filter(r => isCoLatroRepo(r.repo));
  const engine   = engineAll.filter(r => isCoLatroRepo(r.repo));
  const { kept: reviewer, hidden } = filterVerdicts(verdictAll, issueMap);

  renderBanners({ v, w, e, hidden });
  $("rollup").innerHTML = rollupHTML(worker, reviewer, engine);
  $("lanes").innerHTML =
      laneHTML({ key:"worker",   title:"Worker",   icon:"🔧", sub:"authors green PRs",      file:FILES.worker },   worker,   w)
    + laneHTML({ key:"reviewer", title:"Reviewer", icon:"🔎", sub:"approve / request-changes", file:FILES.verdicts }, reviewer, v)
    + laneHTML({ key:"engine",   title:"Engine",   icon:"⚙️", sub:"3rd fleet tier (PET-184)", file:FILES.engine },   engine,   e);

  setUpdated();
  const total = worker.length + reviewer.length + engine.length;
  setStatus(`${total} Co-latro run(s) · ${reviewer.length} verdict(s)`);
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
  load();
  startTimer();
});
