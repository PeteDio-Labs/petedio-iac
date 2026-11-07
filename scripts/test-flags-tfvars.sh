#!/usr/bin/env bash
# Checks environments/homelab/flags.auto.tfvars (PET-884): every key is a declared bool variable
# and every value is true or false, so a typo cannot reach CI as an unused or malformed gate.
set -uo pipefail
cd "$(dirname "$0")/../environments/homelab"
FAIL=0; N=0
while IFS= read -r line; do
  line="${line%%#*}"; [[ "$line" =~ [^[:space:]] ]] || continue
  if [[ ! "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$ ]]; then echo "FAIL malformed line: $line"; FAIL=1; continue; fi
  k="${BASH_REMATCH[1]}"; N=$((N+1))
  grep -Pzoq "variable \"$k\" \{[^}]*?type\s*=\s*bool" *.tf || { echo "FAIL $k is not a bool variable in environments/homelab"; FAIL=1; }
done < flags.auto.tfvars
[ "$N" -gt 0 ] || { echo "FAIL flags.auto.tfvars held no gates"; exit 1; }
echo "flags: $N gates examined, fail=$FAIL"; exit "$FAIL"
