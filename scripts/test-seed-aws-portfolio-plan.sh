#!/usr/bin/env bash
# test-seed-aws-portfolio-plan.sh — run seed-aws-portfolio-plan.sh against stub aws, mc and vault
# commands (PET-884). It checks four things a review found:
#   1. a MinIO password that contains = and : survives the credential file, and reaches mc by stdin only;
#   2. no secret appears in any command's argv;
#   3. --rotate keeps the old AWS key and MinIO account when the Vault write fails;
#   4. --rotate revokes them after the new credentials are stored and read back.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
PW='p@ss=wo:rd with"q'
printf 'ROOT_USER=minioadmin\nROOT_PASSWORD=%s\n' "$PW" > "$W/minio-creds"

cat > "$W/bin/aws" <<'S'
#!/usr/bin/env bash
echo "aws $*" >> "$STUB_LOG"
case "$*" in
  *"sts get-caller-identity"*) echo 847547470418 ;;
  *"iam get-user"*) exit 0 ;;
  *"list-access-keys"*) echo "AKIAOLDKEY0000000000" ;;
  *"create-access-key"*) echo '{"AccessKey":{"AccessKeyId":"AKIANEWKEY0000000000","SecretAccessKey":"NEWAWSSECRET"}}' ;;
esac
S
cat > "$W/bin/mc" <<'S'
#!/usr/bin/env bash
echo "mc $*" >> "$STUB_LOG"
case "$*" in
  *"alias set"*) timeout 2 cat > "$STUB_STDIN" || true; exit 0 ;;
  *"svcacct add"*) echo '{"accessKey":"NEWMINIOAK","secretKey":"NEWMINIOSECRET"}' ;;
esac
S
cat > "$W/bin/vault" <<'S'
#!/usr/bin/env bash
echo "vault $*" >> "$STUB_LOG"
case "$1 $2" in
  "token lookup") exit 0 ;;
  "kv get")
    f="${*: -2:1}"; f="${f#-field=}"
    [ -f "$STUB_VAULT" ] || exit 2
    jq -er --arg f "$f" '.[$f]' "$STUB_VAULT" ;;
  "kv put") [ "${STUB_VAULT_FAIL:-0}" = 1 ] && exit 1; cp "${4#@}" "$STUB_VAULT" ;;
esac
S
chmod +x "$W/bin/"*
run(){ # args...
  : > "$W/log"; : > "$W/stdin"
  PATH="$W/bin:$PATH" STUB_LOG="$W/log" STUB_STDIN="$W/stdin" STUB_VAULT="$W/vault.json" \
    VAULT_TOKEN=t MINIO_CREDS_FILE="$W/minio-creds" bash "$ROOT/scripts/seed-aws-portfolio-plan.sh" --profile test "$@" >"$W/out" 2>&1
}
fail(){ echo "FAIL: $*"; sed 's/^/  | /' "$W/out" | tail -n 15; exit 1; }

# 1 and 2: first run
run || fail "first run exited non-zero"
[ "$(sed -n 2p "$W/stdin")" = "$PW" ] || fail "the MinIO password did not reach mc intact by stdin"
grep -qF "$PW" "$W/log" && fail "the MinIO password appears in a command's argv"
grep -qE 'NEWAWSSECRET|NEWMINIOSECRET' "$W/log" && fail "a new secret appears in a command's argv"
jq -e '.aws_access_key_id=="AKIANEWKEY0000000000" and .minio_access_key=="NEWMINIOAK"' "$W/vault.json" >/dev/null || fail "Vault did not receive the new credentials"

# 3: rotation with a failing Vault write must delete nothing
cp "$W/vault.json" "$W/vault.before"
STUB_VAULT_FAIL=1 run --rotate && fail "rotation with a failed Vault write exited zero"
grep -q 'delete-access-key' "$W/log" && fail "rotation revoked an AWS key after a failed Vault write"
grep -q 'svcacct rm' "$W/log" && fail "rotation removed a MinIO account after a failed Vault write"
cmp -s "$W/vault.before" "$W/vault.json" || fail "Vault content changed after a failed write"

# 4: a good rotation revokes the old key afterwards
sed -i 's/AKIANEWKEY0000000000/AKIANEWKEY1111111111/' "$W/bin/aws"
jq '.minio_access_key="OLDMINIOAK"' "$W/vault.json" > "$W/v2" && mv "$W/v2" "$W/vault.json"
run --rotate || fail "good rotation exited non-zero"
grep -q 'delete-access-key.*AKIAOLDKEY0000000000' "$W/log" || fail "rotation did not revoke the old AWS key"
grep -q 'svcacct rm adm OLDMINIOAK' "$W/log" || fail "rotation did not remove the old MinIO account"
echo "ok: stdin-only secrets, intact password, rotation keeps old credentials on a failed write and revokes after a good one"
