#!/usr/bin/env bash
# engine-candidates.sh — list the Bucket-B issues the engine MAY pick up (PET-184).
#
# The engine's worklist is the *same shape* as the worker's — Todo Co-latro issues carrying
# a routing label — but a DIFFERENT bucket: Bucket-B (needs a NEW effect `kind`), gated by the
# `engine-ok` label instead of the worker's `worker-ok`. So this is an honest thin wrapper over
# scripts/worker/worker-candidates.sh (one Linear GraphQL poll, kept in one place so it can't
# drift) with the label + a distinct MCP-delegation note swapped in.
#
# READ-ONLY by construction (it never claims/branches/comments) — same as the worker poll:
#   * With a Linear token (env LINEAR_API_KEY / Vault kv/services/linear:api_key via the
#     on-disk Vault Agent token) it prints the real candidate JSON array.
#   * Without one it prints `[]` + a note telling Claude to enumerate Bucket-B candidates via
#     the Linear MCP (see docs/runbooks/engine-loop.md), then pick the biggest-cluster-first
#     kind per PET-184 Phase 2.
#
# CLAUDE (always) decides WHICH kind to attack (biggest Bucket-A unlock first), reads the full
# spec, and owns the round-trip cap — a shell filter can't reason over an issue body.
#
# Usage:  scripts/engine/engine-candidates.sh
# Env:    ENGINE_OK_LABEL   the Bucket-B gate label (default: engine-ok).
#         plus every WORKER_LINEAR_* / LINEAR_API_KEY var honored by worker-candidates.sh.
# Output (stdout): JSON array [{"key","title","repo","branch_slug","state","labels"}] (or []).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_CANDIDATES="$SCRIPT_DIR/../worker/worker-candidates.sh"
[ -x "$WORKER_CANDIDATES" ] || { printf '\033[1;31mERROR: worker-candidates.sh not found/executable: %s\033[0m\n' "$WORKER_CANDIDATES" >&2; exit 1; }

# Bucket-B label routes to the engine; everything else (team, repo map, Linear auth) is shared.
export WORKER_OK_LABEL="${ENGINE_OK_LABEL:-engine-ok}"
exec "$WORKER_CANDIDATES" "$@"
