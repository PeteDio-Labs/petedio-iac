#!/usr/bin/env bash
# seed-vault-oidc.sh — create Authentik's "vault" application over its API and write Vault's
# auth/oidc/config from it, in one run (PET-946). Run it once, after
# scripts/apply-vault-config.sh has mounted the method (environments/homelab/vault-config/oidc.tf)
# and before anyone signs in with OIDC.
#
# The Authentik call uses the API token at kv/services/authentik-api (key api_token), read
# with the Vault token below. scripts/seed-authentik-api-token.sh mints it: run that first. It creates one OAuth2 provider and one application, slug `vault`:
# confidential client, implicit consent, scopes openid/email/profile, RS256 signing, and the
# redirect URIs for the Vault page and the CLI (Authentik 2024.12 or later). If the application already exists, it reads the
# client back and creates nothing. It does not touch any other Authentik object.
#
# If Authentik refuses the token, set VAULT_OIDC_CLIENT_ID and VAULT_OIDC_CLIENT_SECRET from an
# app you made by hand (same slug and redirect URIs), and the script skips Authentik.
#
# Bash 3.2 (the Mac's /bin/bash) matches quotes inside a heredoc that sits in $( ), so the Python
# lives in a function and the command substitution only calls it. The bash32 check in CI parses
# this file with a real bash 3.2 (.github/workflows/bash32.yml).
#
# Idempotent. Prints no secret, and the secret never appears in an argument list or in state.
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#   Authentik:   $AUTHENTIK_URL (default https://auth.pdlab.dev)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
export AUTHENTIK_URL="${AUTHENTIK_URL:-https://auth.pdlab.dev}"
APP_SLUG="vault"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v vault >/dev/null || die "vault not in PATH."
command -v python3 >/dev/null || die "python3 not in PATH."

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Checking the method is mounted"
vault auth list -format=json | python3 -c 'import json,sys; sys.exit(0 if "oidc/" in json.load(sys.stdin) else 1)' \
  || die "auth/oidc is not mounted. Apply vault-config first: scripts/apply-vault-config.sh"
vault read -format=json auth/oidc/role/pedro >/dev/null 2>&1 \
  || die "role pedro is missing. Apply vault-config first: scripts/apply-vault-config.sh"

if [ -n "${VAULT_OIDC_CLIENT_ID:-}" ] && [ -n "${VAULT_OIDC_CLIENT_SECRET:-}" ]; then
  step "Using the client from the environment (Authentik skipped)"
  CONFIG_SOURCE=env
else
  step "Creating or reading the Authentik application"
  CONFIG_SOURCE=authentik
  AK_TOKEN="$(vault kv get -field=api_token kv/services/authentik-api 2>/dev/null || true)"
  [ -n "$AK_TOKEN" ] || die "kv/services/authentik-api has no api_token. Run scripts/seed-authentik-api-token.sh first, or set VAULT_OIDC_CLIENT_ID and VAULT_OIDC_CLIENT_SECRET from a hand-made app."
  export AK_TOKEN
fi

step "Writing auth/oidc/config"
# The JSON goes through stdin, so the secret never appears in a process list. The Python is in a
# function (see the header), and the JSON is captured before vault write, so a failed Authentik
# call is the only error shown.
make_config() {
CONFIG_SOURCE="$CONFIG_SOURCE" APP_SLUG="$APP_SLUG" python3 - <<'PY'
import json, os, re, ssl, sys, urllib.error, urllib.request

def out(client_id, client_secret):
    base = os.environ["AUTHENTIK_URL"].rstrip("/")
    print(json.dumps({
        "oidc_discovery_url": f"{base}/application/o/{os.environ['APP_SLUG']}/",
        "oidc_client_id": client_id,
        "oidc_client_secret": client_secret,
        "default_role": "pedro",
    }))

if os.environ["CONFIG_SOURCE"] == "env":
    out(os.environ["VAULT_OIDC_CLIENT_ID"], os.environ["VAULT_OIDC_CLIENT_SECRET"])
    sys.exit(0)

base = os.environ["AUTHENTIK_URL"].rstrip("/")
slug = os.environ["APP_SLUG"]
token = os.environ["AK_TOKEN"]

def api(method, path, body=None):
    req = urllib.request.Request(
        f"{base}/api/v3{path}", method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                 # Cloudflare blocks Python's default urllib agent with error 1010.
                 "User-Agent": "petedio-seed-vault-oidc"})
    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # Print the status and Authentik's reason, never the request (it holds the token).
        sys.exit(f"Authentik {method} {path} -> HTTP {e.code}: {e.read().decode()[:300]}")
    except urllib.error.URLError as e:
        sys.exit(f"Authentik {method} {path} -> no answer from {base}: {e.reason}")

version = api("GET", "/admin/version/")["version_current"]
apps = api("GET", f"/core/applications/?slug={slug}")["results"]
print(f"authentik {version}; application {slug!r} exists: {bool(apps)}", file=sys.stderr)

if apps:
    provider_pk = apps[0]["provider"]
    if provider_pk is None:
        sys.exit(f"application {slug!r} has no provider; fix it in Authentik, then run again.")
else:
    def one(path, what):
        rows = api("GET", path)["results"]
        if len(rows) != 1:
            sys.exit(f"expected exactly one {what}, found {len(rows)}")
        return rows[0]["pk"]

    flow = one("/flows/instances/?slug=default-provider-authorization-implicit-consent", "implicit-consent flow")
    scopes = [one(f"/propertymappings/provider/scope/?managed=goauthentik.io/providers/oauth2/scope-{s}", f"scope {s}")
              for s in ("openid", "email", "profile")]
    key = one("/crypto/certificatekeypairs/?has_key=true&name=authentik%20Self-signed%20Certificate", "signing key")

    uris = ["https://192.168.50.223:8200/ui/vault/auth/oidc/oidc/callback", "https://vault.pdlab.dev/ui/vault/auth/oidc/oidc/callback", "http://localhost:8250/oidc/callback"]
    # From 2024.12 the field is a list of {matching_mode, url} objects, and the provider needs an
    # invalidation flow (checked against the 2024.12.5 serializers). Strict matching: exact URLs.
    year, minor = (int(x) for x in re.match(r"(\d+)\.(\d+)", version).groups())
    if (year, minor) < (2024, 12):
        sys.exit(f"authentik {version} predates 2024.12; this script writes the 2024.12+ provider shape.")
    redirect = [{"matching_mode": "strict", "url": u} for u in uris]

    inv = None
    for inv_slug in ("default-provider-invalidation-flow", "default-invalidation-flow"):
        rows = api("GET", f"/flows/instances/?slug={inv_slug}")["results"]
        if len(rows) == 1:
            inv = rows[0]["pk"]
            break
    if inv is None:
        sys.exit("no default invalidation flow found (tried default-provider-invalidation-flow, default-invalidation-flow).")

    provider = api("POST", "/providers/oauth2/", {
        "name": "Vault", "authorization_flow": flow, "invalidation_flow": inv, "client_type": "confidential",
        "redirect_uris": redirect, "property_mappings": scopes, "signing_key": key,
        "sub_mode": "user_email", "include_claims_in_id_token": True,
    })
    provider_pk = provider["pk"]
    api("POST", "/core/applications/", {"name": "Vault", "slug": slug, "provider": provider_pk})
    print("created the provider and application", file=sys.stderr)

p = api("GET", f"/providers/oauth2/{provider_pk}/")
if not p.get("client_id") or not p.get("client_secret"):
    sys.exit("Authentik returned no client id or secret for the provider.")
out(p["client_id"], p["client_secret"])
PY
}
OIDC_CONFIG_JSON="$(make_config)" || die "could not build the OIDC config; nothing was written to Vault."
[ -n "$OIDC_CONFIG_JSON" ] || die "the OIDC config came back empty; nothing was written to Vault."
printf '%s' "$OIDC_CONFIG_JSON" | vault write auth/oidc/config - >/dev/null

step "Read-back"
vault read -format=json auth/oidc/config | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print("discovery url :", d.get("oidc_discovery_url"))
print("client id set :", bool(d.get("oidc_client_id")))
print("default role  :", d.get("default_role"))'
printf '\nDone. No secret was printed. Sign in at https://192.168.50.223:8200 with method OIDC.\n'
