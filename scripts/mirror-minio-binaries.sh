#!/usr/bin/env bash
# Publish the pinned MinIO server and mc binaries to the lab mirror (PET-801).
#
# The minio role downloads from the `minio-binaries` release of this repo because
# dl.min.io returns 410 Gone. Run this once per version bump, as Pedro, signed in to `gh`
# with write access to PeteDio-Labs/petedio-iac:
#   bash scripts/mirror-minio-binaries.sh --server <file> --mc <file>
# Fetch the server file from LXC 221: `scp root@192.168.50.221:/usr/local/bin/minio .`
# The file has no executable bit, so call it with bash.
#
# FAILS CLOSED. Each file's sha256 must equal the pin in
# ansible/roles/minio/defaults/main.yml, or the script uploads nothing. After the upload
# it downloads each asset back and checks the hash again, so a stale or partial asset
# cannot read as a pass.
set -uo pipefail

repo="PeteDio-Labs/petedio-iac"
tag="minio-binaries"
defaults="$(cd "$(dirname "$0")/.." && pwd)/ansible/roles/minio/defaults/main.yml"

server="" mc=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) server="${2:-}"; shift 2 ;;
    --mc) mc="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -f "$server" ] && [ -f "$mc" ] || { echo "Usage: bash $0 --server <file> --mc <file>" >&2; exit 2; }
command -v gh >/dev/null || { echo "gh is not installed." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in." >&2; exit 1; }

pin() { sed -n "s/^$1: \"\(.*\)\"/\1/p" "$defaults"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

ver_server="$(pin minio_version)"; sha_server="$(pin minio_sha256)"
ver_mc="$(pin minio_mc_version)";  sha_mc="$(pin minio_mc_sha256)"
for v in "$ver_server" "$sha_server" "$ver_mc" "$sha_mc"; do
  [ -n "$v" ] || { echo "Could not read a pin from $defaults." >&2; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failed=0
declare -a names=("minio.${ver_server}" "mc.${ver_mc}")
declare -a files=("$server" "$mc")
declare -a pins=("$sha_server" "$sha_mc")

for i in 0 1; do
  got="$(sha "${files[$i]}")"
  if [ "$got" != "${pins[$i]}" ]; then
    echo "REFUSED ${names[$i]}: file sha256 $got, pin ${pins[$i]}." >&2
    failed=1
  else
    echo "ok pin match: ${names[$i]}"
  fi
done
[ "$failed" -eq 0 ] || { echo "Nothing uploaded." >&2; exit 1; }

gh release view "$tag" -R "$repo" >/dev/null 2>&1 || \
  gh release create "$tag" -R "$repo" --title "MinIO binaries (lab mirror)" \
    --notes "Pinned MinIO server and mc binaries for roles/minio (PET-801). Published by scripts/mirror-minio-binaries.sh." || exit 1

for i in 0 1; do
  cp "${files[$i]}" "$tmp/${names[$i]}"
  gh release upload "$tag" "$tmp/${names[$i]}" -R "$repo" --clobber || failed=1
done

for i in 0 1; do
  gh release download "$tag" -R "$repo" -p "${names[$i]}" -D "$tmp/back" --clobber || { failed=1; continue; }
  back="$(sha "$tmp/back/${names[$i]}")"
  if [ "$back" = "${pins[$i]}" ]; then echo "VERIFIED ${names[$i]} $back"; else echo "MISMATCH ${names[$i]} $back" >&2; failed=1; fi
done
[ "$failed" -eq 0 ] && echo "Mirror verified: 2 of 2 assets match the pins." || { echo "Mirror NOT verified." >&2; exit 1; }
