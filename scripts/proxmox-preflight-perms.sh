#!/usr/bin/env bash
# proxmox-preflight-perms.sh — fail LOUD at PR/apply time if the IaC token is missing a
# Proxmox privilege the config needs, instead of a green plan-on-PR that 403s at apply
# (PET-160, the prevention half of the PET-159 Pool.Allocate poison pill).
#
# READ-ONLY by construction: the ONLY call it makes is GET /access/permissions, which returns
# the calling token's own effective permissions. It never writes, never applies, never imports.
# It does NOT touch Vault — it uses the token already present in the environment (CI mints it
# from Vault into TF_VAR_proxmox_api_token; locally, export it yourself). Per the PET-160 hard
# boundary: the token is referenced by env name only and never printed; the pveum ACL grant
# that FIXES a gap is Pedro's on root@pam, never this script's.
#
# Usage:
#   scripts/proxmox-preflight-perms.sh --require Pool.Allocate --require Pool.Audit [--path /pool/homelab]
#   scripts/proxmox-preflight-perms.sh --require Pool.Allocate --dry-run    # print plan, no API call
#
# Options:
#   --require <Priv>   a privilege that must be granted (repeatable; at least one required)
#   --path <path>      ACL path the privs must cover (default: /pool/homelab). A priv granted on
#                      this path OR any ancestor (/, /pool, …) satisfies the check (propagation).
#   --dry-run          print what would be checked and exit 0 without calling the API / a token
#
# Env (optional):
#   PROXMOX_API_TOKEN  full 'user@realm!tokenid=secret' (else TF_VAR_proxmox_api_token). Never printed.
#   PROXMOX_PREFLIGHT_ENDPOINT   default https://192.168.50.10:8006 (matches var.proxmox_endpoint).
#
# Exit: 0 = all required privs present (or --dry-run); 1 = a priv is missing (message names it +
# the fix); 2 = harness error (no token / endpoint unreachable).
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 2; }

REQUIRE=() TARGET_PATH="/pool/homelab" DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --require) REQUIRE+=("$2"); shift 2 ;;
    --path) TARGET_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done
[ "${#REQUIRE[@]}" -gt 0 ] || die "give at least one --require <Priv>. See --help."

ENDPOINT="${PROXMOX_PREFLIGHT_ENDPOINT:-https://192.168.50.10:8006}"
ENDPOINT="${ENDPOINT%/}"

if [ "$DRY_RUN" = true ]; then
  printf 'preflight (dry-run): would check %s on %s (or an ancestor) at %s\n' \
    "${REQUIRE[*]}" "$TARGET_PATH" "$ENDPOINT" >&2
  exit 0
fi

for t in curl python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

TOKEN="${PROXMOX_API_TOKEN:-${TF_VAR_proxmox_api_token:-}}"
[ -n "$TOKEN" ] || die "no IaC token in env (PROXMOX_API_TOKEN / TF_VAR_proxmox_api_token). In CI this is minted from Vault by the OIDC step."

# Read-only: the token's own effective permissions. -k: self-signed homelab cert (insecure=true
# in providers.tf). The token is sent in the header only, never logged.
resp="$(curl -fsSk -H "Authorization: PVEAPIToken=${TOKEN}" "${ENDPOINT}/api2/json/access/permissions")" ||
  die "GET ${ENDPOINT}/api2/json/access/permissions failed (token valid? node reachable from here?)."

# Build the ancestor path list for the target (e.g. /pool/homelab -> "/","/pool","/pool/homelab").
ancestors="/"
acc=""
IFS='/' read -ra parts <<<"${TARGET_PATH#/}"
for p in "${parts[@]}"; do
  [ -n "$p" ] || continue
  acc="${acc}/${p}"
  ancestors="${ancestors} ${acc}"
done

missing="$(
  RESP="$resp" ANCESTORS="$ancestors" TARGET="$TARGET_PATH" python3 - "${REQUIRE[@]}" <<'PY'
import json, os, sys

required = sys.argv[1:]
perms = json.loads(os.environ["RESP"]).get("data", {})
ancestors = os.environ["ANCESTORS"].split()

def granted(priv):
    # A priv is held if it's 1 on the target path or any ancestor (Proxmox ACL propagation).
    for path in ancestors:
        node = perms.get(path)
        if isinstance(node, dict) and node.get(priv) in (1, True):
            return True
    return False

print("\n".join(p for p in required if not granted(p)))
PY
)"

if [ -n "$missing" ]; then
  TOKEN_ID="${TOKEN%%=*}" # 'user@realm!tokenid' — the part before '=secret'; safe to show.
  printf '\033[1;31mPREFLIGHT FAILED:\033[0m token %s is missing required Proxmox privilege(s) on %s:\n' \
    "$TOKEN_ID" "$TARGET_PATH" >&2
  while IFS= read -r p; do [ -n "$p" ] && printf '  - %s\n' "$p" >&2; done <<<"$missing"
  printf 'Fix (operator, root@pam — PET-159 runbook): grant the missing priv(s) to %s, e.g.\n' "$TOKEN_ID" >&2
  printf "  pveum role add IaCPoolUser -privs 'Pool.Allocate,Pool.Audit'\n" >&2
  printf "  pveum acl modify %s -roles IaCPoolUser -tokens '%s'\n" "$TARGET_PATH" "$TOKEN_ID" >&2
  printf 'Then re-run. (This check is read-only; it never grants anything.)\n' >&2
  exit 1
fi

printf '\033[1;32mpreflight ok: %s present on %s (or an ancestor).\033[0m\n' "${REQUIRE[*]}" "$TARGET_PATH" >&2
