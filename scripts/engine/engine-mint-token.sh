#!/usr/bin/env bash
# engine-mint-token.sh — mint the petedio-engine[bot] installation token (PET-184).
# Thin wrapper over scripts/agent-mint-token.sh. Prints the token to stdout (use as
# GH_TOKEN); push-branches + open-PRs scope, structurally cannot merge (like the worker).
# See that script and docs/runbooks/engine-loop.md.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-mint-token.sh" engine "$@"
