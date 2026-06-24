# Mission Control v3 — live PR board (PET-158)

A **single self-contained HTML artifact** (`index.html`) — no backend, no build step, no host.
Open it in a browser; it reads live state at runtime from **GitHub** and **Linear**, joins each
open PR to its Linear issue on the `PET-<n>` key, and surfaces the merge-readiness signal Pedro
triages by. **Read-only**: it never merges, comments, mutates labels, or writes anything.

Sibling to PET-155 (the JSONL viewer over the MinIO event stream) — **not** the same dashboard.
This one is the day-to-day PR triage board; PET-155 is the lifecycle-event viewer.

## Use it

1. Open `index.html` in a browser (double-click, or serve the folder statically).
2. Paste a **GitHub token** (PAT with read access to the org repos) and, optionally, a **Linear
   API key**. Set the org, repo list, Linear team key (`PET`), and the loop account login(s).
3. **↻ Refresh.** Tokens stay in your browser only; "remember tokens" persists them to
   `localStorage` (opt-in). Nothing is sent anywhere except `api.github.com` and `api.linear.app`.

## Runtime cred injection — NOTHING is embedded or committed

The artifact contains **no secrets**. Tokens are injected at runtime via the input fields. Store
the real values in Vault and copy them in by hand (or wire injection in your host context):

- **GitHub PAT** → Vault `kv/services/agent-loop` (a read-scoped token; or your own PAT). Path by
  name only — never paste the value into the repo.
- **Linear API key** → Vault `kv/services/linear` (field `api_key`) once provisioned (this path is
  also the one PET-145 / PET-147 want for headless Linear access). Until it exists, use a personal
  Linear key at runtime.

The board reads with these tokens; it has **read-only** scope by intent and performs no writes.

## What it shows

Per open PR (across the org repos): repo, **PET-id** (links to the Linear issue), PR #/title
(links to GitHub), author (**loop** vs **human**), draft/ready, **checks**, **mergeable**, Linear
**status**, key **labels** (`agent-reviewed`, `changes-requested`, `import-gated`, `needs-human`),
and age.

**Merge-ready** section implements the fast-merge rule:
`In Review` + `agent-reviewed` + checks green + mergeable + **not** `import-gated` (+ not draft).
`import-gated` rows are visually flagged (⛔) and **excluded** from merge-ready regardless of other
signals.

**Merge state is shown only as GitHub reports it** (`mergeable`, `statusCheckRollup`) — never
inferred from Linear's lagging PR sync (hard rule 7 / the PR #50 lesson).

## Graceful degradation

- No Linear key, or Linear unreachable → the **GitHub board still renders**, with a per-source
  banner; merge-readiness (which needs Linear status/labels) is disabled.
- A repo that 404s / is inaccessible is skipped, not fatal.
- No GitHub token → an empty state with instructions, never a crash.

## Design notes for Pedro (decisions / Manual steps)

- **Repo home — your call.** Per the Agent Loop Operations doc there's no home in the current
  repo map for a standalone dashboard. It's placed at `petedio-iac/tools/mission-control/` as a
  pragmatic default (Platform issue; one self-contained file). **Relocate freely** — it's a single
  HTML file with no repo coupling.
- **Linear in a *truly* standalone browser file may hit CORS.** GitHub's GraphQL API is
  browser-CORS-clean; Linear's may reject a browser `Authorization` from arbitrary origins
  depending on key type. The board degrades gracefully if so (GitHub-only + banner). To get live
  Linear in every context, either run it where Linear is reachable (a Claude artifact wired to the
  Linear MCP, or behind your own trusted origin) or front Linear with a **tiny read-only proxy** —
  **NOT built here** (the issue forbids a backend; this is a note, not an implementation).
- **Optional later enrichment:** when PET-154's JSONL lifecycle stream lands, rows can be enriched
  with the latest event — additive, not a dependency.

## Hard-rule compliance

Read-only viewer. No writes (merge/label/comment). **No secrets** in the artifact or repo — tokens
are runtime-injected; Vault paths referenced by name only. No backend, no new host.
