#!/usr/bin/env bash
# Turn on GitHub secret scanning, push protection and validity checks for the public
# PeteDio-Labs repositories (PET-683), then read the setting back.
#
# Run it as Pedro, signed in to `gh` with admin rights on each repo:
#   bash scripts/enable-secret-scanning.sh            # petedio-iac and pete-bot
#   bash scripts/enable-secret-scanning.sh <repo>...  # other public repos
# The file has no executable bit, so call it with bash.
#
# Private repos need paid GitHub Advanced Security, so the gitleaks check covers them.
#
# FAILS CLOSED. The script exits non-zero unless the read-back shows all three settings
# `enabled` on every repo it names. It prints each repo's status so a repo that was skipped
# or refused cannot look like one that passed.
set -uo pipefail

owner="PeteDio-Labs"
repos=("$@")
[ "${#repos[@]}" -gt 0 ] || repos=(petedio-iac pete-bot)

command -v gh >/dev/null || { echo "gh is not installed." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in." >&2; exit 1; }

failed=0
for repo in "${repos[@]}"; do
  echo "== ${owner}/${repo}"
  if ! gh api -X PATCH "repos/${owner}/${repo}" \
      -F 'security_and_analysis[secret_scanning][status]=enabled' \
      -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
      -F 'security_and_analysis[secret_scanning_validity_checks][status]=enabled' \
      --silent; then
    echo "PATCH refused for ${repo}." >&2
    failed=1
    continue
  fi
  # Read back. Count the enabled settings so zero reads cannot pass.
  status=$(gh api "repos/${owner}/${repo}" \
    --jq '.security_and_analysis | [.secret_scanning.status, .secret_scanning_push_protection.status, .secret_scanning_validity_checks.status] | @tsv')
  echo "secret_scanning / push_protection / validity_checks: ${status}"
  enabled=$(printf '%s' "$status" | tr '\t' '\n' | grep -c '^enabled$' || true)
  echo "${enabled} of 3 enabled"
  [ "$enabled" -eq 3 ] || failed=1
done

if [ "$failed" -ne 0 ]; then
  echo "At least one repo is not fully enabled." >&2
  exit 1
fi
echo "All ${#repos[@]} repos report 3 of 3 enabled."
