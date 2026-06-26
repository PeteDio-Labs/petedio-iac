#!/usr/bin/env bash
# reviewer-mint-token.sh — mint the petedio-reviewer[bot] installation token (PET-176).
# Thin wrapper over scripts/agent-mint-token.sh. Prints the token to stdout (use as
# GH_TOKEN) so `gh pr review --approve|--request-changes` posts under a distinct identity
# from the PR author (no self-review block). Read-repo + write-PR-reviews scope, no push,
# no merge. See that script and docs/runbooks/reviewer-loop.md.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-mint-token.sh" reviewer "$@"
