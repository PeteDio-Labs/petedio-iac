#!/usr/bin/env bash
# bash32-canary.sh: the construct that broke scripts/seed-vault-oidc.sh on the Mac (PET-946).
# bash 3.2 matches quotes inside a heredoc that sits in $( ), so the apostrophe in the Python
# comment below leaves a quote open, and /bin/bash -n reports "unexpected EOF". bash 4 and later
# accept this file. .github/workflows/bash32.yml requires /bin/bash -n to REJECT it, which proves
# the check parses with a real bash 3.2 and does not pass because it examined nothing.
# Never run this file. Never "fix" it: the break is the point.
OUT="$(python3 - <<'PY'
# Cloudflare blocks Python's default agent.
print("x")
PY
)"
echo "$OUT"
