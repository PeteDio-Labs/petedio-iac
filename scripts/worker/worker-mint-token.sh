#!/usr/bin/env bash
# worker-mint-token.sh — mint the petedio-worker[bot] installation token (PET-176).
# Thin wrapper over scripts/agent-mint-token.sh. Prints the token to stdout (use as
# GH_TOKEN); push-branches + open-PRs scope, structurally cannot merge. See that script
# and docs/runbooks/worker-loop.md.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-mint-token.sh" worker "$@"
