#!/usr/bin/env bash
# test-seed-vault-oidc.sh: drive scripts/seed-vault-oidc.sh against a fake vault. No network, no
# credentials. Runs in keys-check.yml.
#
#   - env mode builds the JSON and hands it to `vault write auth/oidc/config -` on stdin;
#   - a failed Authentik call (nothing listens on the URL) stops the script before any write;
#   - the client secret appears in no command's arguments.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/seed-vault-oidc.sh"
[ -f "$SCRIPT" ] || { echo "test-seed-vault-oidc: no script at $SCRIPT"; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
SECRET=FAKESECRET0123456789

cat > "$W/bin/vault" <<'SH'
#!/usr/bin/env bash
printf 'vault %s\n' "$*" >> "$FAKE_ARGS_LOG"
case "$1 $2" in
  "token lookup") exit 0 ;;
  "auth list") echo '{"oidc/":{}}' ;;
  "read -format=json")
    case "$3" in
      auth/oidc/role/pedro) echo '{}' ;;
      auth/oidc/config) echo '{"data":{"oidc_discovery_url":"u","oidc_client_id":"id","default_role":"pedro"}}' ;;
    esac ;;
  "write auth/oidc/config") cat > "$FAKE_DIR/written" ;;
  "kv get") echo "${FAKE_AK_TOKEN:-}" ;;
  *) echo "unexpected vault $*" >&2; exit 1 ;;
esac
SH
chmod +x "$W/bin/vault"

pass=0 fail=0 n=0
run() {  # <want> <label> [VAR=value ...]
  want="$1"; label="$2"; shift 2; n=$((n + 1))
  rm -f "$W/written"; : > "$W/args.log"
  got=stop
  if out="$(env "$@" PATH="$W/bin:$PATH" FAKE_DIR="$W" FAKE_ARGS_LOG="$W/args.log" VAULT_TOKEN=fake "${TEST_BASH:-bash}" "$SCRIPT" 2>&1)"; then got=pass; fi
  problem=""
  [ "$got" = "$want" ] || problem="got $got, want $want"
  grep -q "$SECRET" "$W/args.log" && problem="$problem; secret in arguments"
  case "$out" in *"$SECRET"*) problem="$problem; secret printed" ;; esac
  if [ "$want" = pass ]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["oidc_client_secret"]==sys.argv[2] and d["default_role"]=="pedro" and d["oidc_discovery_url"].endswith("/application/o/vault/")' "$W/written" "$SECRET" 2>/dev/null \
      || problem="$problem; wrong or missing JSON on stdin"
  else
    [ ! -e "$W/written" ] || problem="$problem; wrote auth/oidc/config on a failure"
  fi
  if [ -n "$problem" ]; then fail=$((fail + 1)); echo "FAIL: $label: $problem"; echo "$out" | sed 's/^/    /'; else pass=$((pass + 1)); fi
}

run pass "env client" VAULT_OIDC_CLIENT_ID=id VAULT_OIDC_CLIENT_SECRET="$SECRET"
run stop "no api token in Vault"
run stop "authentik unreachable" FAKE_AK_TOKEN=tok AUTHENTIK_URL=http://127.0.0.1:9

echo "test-seed-vault-oidc: $pass of $n cases passed"
[ "$fail" = 0 ] && [ "$n" -gt 0 ]
