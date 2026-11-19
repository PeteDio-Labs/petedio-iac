#!/usr/bin/env bash
# seed-authentik-aws.sh — give the AWS Authentik host its secrets and a copy of the lab's data
# (PET-932). Pedro runs it from the Mac, which reaches pve03, Vault and the AWS account.
#
# WHY A SCRIPT. These values are credentials (PET-511), and Terraform would keep them in state:
#   /petedio-authentik/env              LXC 119's /opt/authentik/.env, whole (secret key, PG_PASS, email)
#   /petedio-authentik/tunnel_token     the authentik-aws tunnel token, read from the Cloudflare API
#   /petedio-authentik/tailscale_authkey   only with --tailscale; you paste a key, hidden
# With --copy-data it also copies the database and media folder to s3://<bucket>/migrate/, then
# writes migrate/READY last. The host restores within two minutes and starts the stack. The copy
# runs while the lab copy keeps serving, so nothing goes down. Anything written on the lab after
# the copy (a session, an event, a setting) stays on the lab, so run --copy-data again just before
# the switch. The host refuses a copy once environments/authentik sets accept_restore = false.
#
# Values travel from ssh, Vault and the Cloudflare API into a 0700 temporary directory, then into
# SSM or S3. None reaches argv or the screen. Every failure stops the script with a reason.
#
#   AWS:   a profile for account 847547470418 that can write SSM parameters and the bucket.
#   Vault: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. Reads kv/iac/cloudflare.
#   pve03: ssh as root (default root@192.168.50.10), which runs `pct exec 119`.
#
# Usage:
#   ./scripts/seed-authentik-aws.sh --profile <profile>                   # secrets only
#   ./scripts/seed-authentik-aws.sh --profile <profile> --copy-data       # secrets, then the data
#   ./scripts/seed-authentik-aws.sh --profile <profile> --tailscale       # also join the tailnet
set -euo pipefail
umask 077

PROFILE=""; COPY=0; TS=0; PVE="${PVE_HOST:-root@192.168.50.10}"; VMID=119
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
    --copy-data) COPY=1; shift ;;
    --tailscale) TS=1; shift ;;
    --pve-host) PVE="${2:?--pve-host needs user@host}"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "ABORT: pass --profile <aws profile>." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ACCT="847547470418"; REGION="us-east-2"
BUCKET="petedio-authentik-$ACCT"; PFX="/petedio-authentik"
TUNNEL_NAME="authentik-aws"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in aws vault jq curl ssh shasum; do command -v "$t" >/dev/null || die "$t not in PATH."; done
aws_(){ aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }
sha(){ shasum -a 256 "$1" | cut -d' ' -f1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

put_param(){ # $1 name under $PFX, $2 file holding the value
  jq -n --arg n "$PFX/$1" --rawfile v "$2" '{Name: $n, Value: ($v | rtrimstr("\n")), Type: "SecureString", Overwrite: true, Tier: "Standard"}' > "$TMP/param.json"
  aws_ ssm put-parameter --cli-input-json "file://$TMP/param.json" >/dev/null || die "could not write $PFX/$1."
  rm -f "$TMP/param.json"
  # Read back by digest only, so the value never reaches the screen.
  aws_ ssm get-parameter --with-decryption --name "$PFX/$1" --query Parameter.Value --output text > "$TMP/back"
  [ "$(printf '%s' "$(cat "$2")" | shasum -a 256 | cut -d' ' -f1)" = "$(printf '%s' "$(cat "$TMP/back")" | shasum -a 256 | cut -d' ' -f1)" ] \
    || die "the read-back of $PFX/$1 does not match what was written."
  rm -f "$TMP/back"
  echo "  $PFX/$1 written and read back ($(wc -c < "$2" | tr -d ' ') bytes, value not shown)"
}

step "AWS"
GOT="$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[ "$GOT" = "$ACCT" ] || die "profile '$PROFILE' is account '${GOT:-unreadable}', not $ACCT."
aws_ s3api head-bucket --bucket "$BUCKET" 2>/dev/null || die "s3://$BUCKET does not exist. Run aws-apply.yml for root authentik first."
aws_ s3 cp "s3://$BUCKET/config/settings.env" "$TMP/settings.env" --only-show-errors || die "s3://$BUCKET/config/settings.env is missing. Run aws-apply.yml for root authentik first."
ACCEPT="$(sed -n 's/^ACCEPT_RESTORE=//p' "$TMP/settings.env")"
echo "  account $ACCT, bucket $BUCKET, accept_restore=$ACCEPT"
[ "$COPY" -eq 0 ] || [ "$ACCEPT" = "true" ] || die "accept_restore is $ACCEPT: the AWS copy is live, and a copy from the lab would be refused. Nothing was copied."

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
CF_ACCT="$(vault kv get -field=account_id kv/iac/cloudflare)" || die "could not read account_id from kv/iac/cloudflare."
CF_TOK="$(vault kv get -field=api_token kv/iac/cloudflare)" || die "could not read api_token from kv/iac/cloudflare."
[ -n "$CF_TOK" ] || die "kv/iac/cloudflare holds an empty api_token."
printf 'Authorization: Bearer %s\n' "$CF_TOK" > "$TMP/cf-header"
unset CF_TOK
echo "  read the Cloudflare token (not shown)"

step "Tunnel token for $TUNNEL_NAME"
cf(){ curl -fsS -H "@$TMP/cf-header" "https://api.cloudflare.com/client/v4/accounts/$CF_ACCT/$1"; }
cf "cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" > "$TMP/tunnels.json" || die "the Cloudflare tunnel list failed."
N="$(jq '.result | length' "$TMP/tunnels.json")"
[ "$N" = 1 ] || die "Cloudflare lists $N live tunnels named $TUNNEL_NAME, not 1. Merge the PET-932 homelab change first."
TID="$(jq -r '.result[0].id' "$TMP/tunnels.json")"
cf "cfd_tunnel/$TID/token" | jq -r '.result // empty' > "$TMP/tunnel-token" || die "the tunnel token read failed."
[ -s "$TMP/tunnel-token" ] || die "Cloudflare returned an empty token for tunnel $TID."
put_param tunnel_token "$TMP/tunnel-token"

step "Authentik .env from LXC $VMID on $PVE"
ssh -o BatchMode=yes "$PVE" "pct exec $VMID -- cat /opt/authentik/.env" > "$TMP/env" || die "could not read /opt/authentik/.env from LXC $VMID."
grep -q '^AUTHENTIK_SECRET_KEY=.' "$TMP/env" || die "the .env holds no AUTHENTIK_SECRET_KEY."
grep -q '^PG_PASS=.' "$TMP/env" || die "the .env holds no PG_PASS."
echo "  read $(grep -c '=' "$TMP/env") settings (names only: $(sed -n 's/=.*//p' "$TMP/env" | tr '\n' ' '))"
put_param env "$TMP/env"

if [ "$TS" -eq 1 ]; then
  step "Tailscale"
  echo "  Make a one-off, pre-approved auth key in the Tailscale admin console (tag it if your ACLs use tags)."
  read -rsp "  Paste the auth key (hidden): " k; echo
  [ -n "$k" ] || die "no key pasted."
  printf '%s' "$k" > "$TMP/ts"; unset k
  put_param tailscale_authkey "$TMP/ts"
fi

if [ "$COPY" -eq 1 ]; then
  step "Data copy from LXC $VMID (it keeps serving)"
  PG="$(ssh -o BatchMode=yes "$PVE" "pct exec $VMID -- docker ps --format '{{.Names}}'" | grep -E 'postgres' | head -n 1 || true)"
  [ -n "$PG" ] || die "no running Postgres container on LXC $VMID."
  VER="$(ssh -o BatchMode=yes "$PVE" "pct exec $VMID -- docker exec $PG sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"show server_version_num\"'" | tr -d '[:space:]')"
  case "$VER" in ''|*[!0-9]*) die "could not read the Postgres version from $PG." ;; esac
  [ "$VER" -lt 170000 ] || die "LXC $VMID runs Postgres $VER. The AWS host runs 16, which cannot restore a newer dump. Raise the image in environments/authentik first."
  ssh -o BatchMode=yes "$PVE" "pct exec $VMID -- docker exec $PG sh -c 'pg_dump -Fc -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\"'" > "$TMP/authentik.dump" \
    || die "pg_dump on LXC $VMID failed."
  DS="$(wc -c < "$TMP/authentik.dump" | tr -d ' ')"
  [ "$DS" -gt 100000 ] || die "the dump is $DS bytes, too small for an Authentik database."
  ssh -o BatchMode=yes "$PVE" "pct exec $VMID -- tar -czf - -C /opt/authentik/media ." > "$TMP/media.tar.gz" || die "could not read /opt/authentik/media on LXC $VMID."
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  aws_ s3 cp "$TMP/authentik.dump" "s3://$BUCKET/migrate/authentik.dump" --only-show-errors
  aws_ s3 cp "$TMP/media.tar.gz" "s3://$BUCKET/migrate/media.tar.gz" --only-show-errors
  # READY goes last, so the host never restores half a copy.
  printf '%s %s %s\n' "$STAMP" "$(sha "$TMP/authentik.dump")" "$(sha "$TMP/media.tar.gz")" > "$TMP/READY"
  aws_ s3 cp "$TMP/READY" "s3://$BUCKET/migrate/READY" --only-show-errors
  echo "  copy $STAMP: Postgres $VER, database $DS bytes, media $(wc -c < "$TMP/media.tar.gz" | tr -d ' ') bytes"

  # Wait for the host to report this exact copy. A 2xx from the login page would also come from
  # an earlier copy, so the page is not proof. The host writes backups/status.json on every sync.
  step "Waiting for the host to restore copy $STAMP (up to 10 minutes)"
  for i in $(seq 1 40); do
    if aws_ s3 cp "s3://$BUCKET/backups/status.json" "$TMP/status.json" --only-show-errors 2>/dev/null; then
      phase="$(jq -r '.phase // empty' "$TMP/status.json")"
      got="$(jq -r '.restored_stamp // empty' "$TMP/status.json")"
      detail="$(jq -r '.detail // empty' "$TMP/status.json")"
      case "$phase" in
        ok) [ "$got" != "$STAMP" ] || { echo "  the host serves copy $STAMP and reports healthy ($(jq -r .checked_at "$TMP/status.json"))"; exit 0; } ;;
        error) [ "$got" = "$STAMP" ] || die "the host reports an error: $detail. On the host: aws ssm start-session, then journalctl -u authentik-sync." ;;
        waiting|restoring) : ;;
        *) die "the host's status.json has an unknown phase '$phase'." ;;
      esac
    fi
    sleep 15
  done
  die "after 10 minutes the host reports phase '${phase:-none}' with copy '${got:-none}', not $STAMP. On the host: aws ssm start-session, then journalctl -u authentik-sync."
fi
echo
echo "Done. The host picks the secrets up within two minutes. Run again with --copy-data to start it."
