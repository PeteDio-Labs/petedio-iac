#!/usr/bin/env bash
# test-seed-authentik-api-token.sh: drive scripts/seed-authentik-api-token.sh against fake ssh,
# vault and curl. No network, no credentials. Runs in keys-check.yml.
#
# What it proves, per case:
#   - the happy path stores the key through stdin and checks it against the API;
#   - every failure (no marker, no server container, ssh refused, HTTP 401, 403, 000, 500) stops
#     the script non-zero (.claude/rules/scripts.md: an unrecognized verdict is a fault);
#   - the fake token key never appears in any argument any command received;
#   - the code sent to `ak shell` survives the remote shell: the script's remote string is
#     re-parsed by sh, and the Python that comes out compiles.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/seed-authentik-api-token.sh"
[ -f "$SCRIPT" ] || { echo "test-seed-authentik-api-token: no script at $SCRIPT"; exit 2; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
KEY=FAKEKEY0123456789abcdef
: > "$W/sshkey"

# Fake ssh: argv is everything after the options and the host. The last argument is the remote string.
cat > "$W/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$FAKE_ARGS_LOG"
[ "${FAKE_SSH_FAIL:-0}" = 1 ] && { echo "Permission denied" >&2; exit 255; }
remote="${*: -1}"
case "$remote" in
  *"ps -q server"*)
    [ "${FAKE_NO_SERVER:-0}" = 1 ] || echo abc123 ;;
  *"ak shell -c"*)
    # Re-parse the remote string the way pve03's shell would, with pct as a function that
    # prints its arguments NUL-separated, then take the last one: the code for ak shell.
    argv_file="$FAKE_DIR/argv"
    sh -c "pct() { shift; printf '%s\\0' \"\$@\"; }; $remote" > "$argv_file" || exit 1
    code_arg="$(tr '\0' '\n' < "$argv_file" | tail -n 1)"
    case "$code_arg" in
      'exec(__import__("base64").b64decode("'*'").decode())') ;;
      *) echo "bad code argument: $code_arg" >&2; exit 1 ;;
    esac
    b64="${code_arg#exec(__import__(\"base64\").b64decode(\"}"; b64="${b64%\").decode())}"
    printf '%s' "$b64" | base64 -d > "$FAKE_DIR/mint.py" || exit 1
    python3 -c 'import sys; compile(open(sys.argv[1]).read(), "mint.py", "exec")' "$FAKE_DIR/mint.py" || exit 1
    grep -q INTENT_API "$FAKE_DIR/mint.py" || exit 1
    grep -q 'expiring=True' "$FAKE_DIR/mint.py" || exit 1
    grep -q 'timedelta(hours=24)' "$FAKE_DIR/mint.py" || exit 1
    echo "some warning from ak"
    [ "${FAKE_NO_MARKER:-0}" = 1 ] || echo "MINTED_TOKEN_KEY=$FAKE_KEY" ;;
  *) echo "unexpected remote: $remote" >&2; exit 1 ;;
esac
SH

cat > "$W/bin/vault" <<'SH'
#!/usr/bin/env bash
printf 'vault %s\n' "$*" >> "$FAKE_ARGS_LOG"
case "$1 $2" in
  "token lookup") exit 0 ;;
  "kv put") cat > "$FAKE_DIR/stored"; [ -s "$FAKE_DIR/stored" ] ;;
  "kv get") cat "$FAKE_DIR/stored" ;;
  *) echo "unexpected vault $*" >&2; exit 1 ;;
esac
SH

# Fake curl: the Authorization header must arrive on stdin (--config -), never as an argument.
cat > "$W/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FAKE_ARGS_LOG"
cfg="$(cat)"
case "$cfg" in *"Bearer $FAKE_KEY"*) ;; *) echo "token missing from curl config" >&2; exit 1 ;; esac
printf '%s' "${FAKE_HTTP:-200}"
SH
chmod +x "$W/bin/ssh" "$W/bin/vault" "$W/bin/curl"

pass=0 fail=0 n=0
run() {  # <want: pass|stop> <label> [VAR=value ...]
  want="$1"; label="$2"; shift 2
  n=$((n + 1))
  rm -f "$W/stored" "$W/argv" "$W/args.log"; : > "$W/args.log"
  got=stop
  if out="$(env "$@" PATH="$W/bin:$PATH" FAKE_DIR="$W" FAKE_KEY="$KEY" FAKE_ARGS_LOG="$W/args.log" \
      VAULT_TOKEN=fake PVE_SSH_KEY="$W/sshkey" "${TEST_BASH:-bash}" "$SCRIPT" 2>&1)"; then
    got=pass
  fi
  problem=""
  if [ "$got" != "$want" ]; then problem="got $got, want $want"; fi
  if grep -q "$KEY" "$W/args.log"; then problem="$problem; token key found in a command's arguments"; fi
  case "$out" in *"$KEY"*) problem="$problem; token key printed" ;; esac
  if [ "$want" = pass ] && [ "$(cat "$W/stored" 2>/dev/null)" != "$KEY" ]; then problem="$problem; Vault did not receive the key on stdin"; fi
  if [ "$want" = stop ] && [ -s "$W/stored" ] && [ "$label" != "http 401" ] && [ "$label" != "http 403" ] \
     && [ "$label" != "http 000" ] && [ "$label" != "http 500" ]; then problem="$problem; Vault was written on a failed mint"; fi
  if [ -n "$problem" ]; then fail=$((fail + 1)); echo "FAIL: $label: $problem"; echo "$out" | sed 's/^/    /'; else pass=$((pass + 1)); fi
}

run pass "happy path"
run stop "no server container" FAKE_NO_SERVER=1
run stop "ssh refused" FAKE_SSH_FAIL=1
run stop "no marker line" FAKE_NO_MARKER=1
run stop "http 401" FAKE_HTTP=401
run stop "http 403" FAKE_HTTP=403
run stop "http 000" FAKE_HTTP=000
run stop "http 500" FAKE_HTTP=500
run stop "bad user name" AUTHENTIK_USER="ak;rm"

echo "test-seed-authentik-api-token: $pass of $n cases passed"
[ "$fail" = 0 ] && [ "$n" -gt 0 ]
