#!/bin/sh
# staging-reset — put both staging sites back on their placeholder page (PET-942).
#
# Run inside staging-249 by `pct exec`, from the node's staging-power command, when the work on a
# staging branch is merged into main. The next staging push publishes a fresh build, so the box
# never serves a merged build again. It changes the two `current` links and nothing else.
set -eu
for base in /srv/staging /srv/dashboard-staging; do
  [ -d "$base/releases/placeholder" ] || { echo "staging-reset: $base has no placeholder." >&2; exit 1; }
  ln -sfn "$base/releases/placeholder" "$base/current"
  echo "staging-reset: $base/current -> placeholder"
done
