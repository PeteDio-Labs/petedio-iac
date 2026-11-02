#!/usr/bin/env bash
# test-seed-vault-snapshot-approle — run seed-vault-snapshot-approle.sh end to end against
# stub `vault` and `ssh` commands (PET-790). It contacts nothing. The stub host is a temp
# directory, and the stub Vault keeps its valid secret_ids in a file.
#
#   ./scripts/test-seed-vault-snapshot-approle.sh
#
# It asserts what the script must guarantee: the secret_id never reaches stdout or stderr, the
# files land root-readable only, a re-run changes nothing, a failed proof leaves nothing that can
# log in, and a rotate destroys the old secret_id or records it for retry.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       want %s, got %s\n' "$1" "$2" "$3"; }
eq()  { [ "$3" = "$2" ] && ok "$1" || bad "$1" "[$2]" "[$3]"; }

for t in jq python3; do command -v "$t" >/dev/null || { echo "SKIP: $t not in PATH"; exit 0; }; done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; STATE="$T/state"; HOSTDIR="$T/etc-vault-snapshot"; mkdir -p "$BIN" "$STATE"

cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
# Run the last argument locally, as the stub host. The stub host has the vault CLI and TLS dir.
cmd="${@: -1}"
case "$cmd" in "command -v vault"*) exit 0 ;; esac
exec bash -c "$cmd"
STUB

cat > "$BIN/vault" <<'STUB'
#!/usr/bin/env bash
S="$STATE"; args="$*"
case "$args" in
  "token lookup")                       [ -z "${FAKE_TOKEN_BAD:-}" ]; exit ;;
  "read -format=json auth/approle/role/vault-snapshot")
    echo '{"data":{"token_policies":["vault-snapshot"]}}' ;;
  "read -field=role_id "*)              printf 'ROLEID-123' ;;
  "write -format=json -f auth/approle/role/vault-snapshot/secret-id "*)
    n=$(( $(cat "$S/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/n"
    echo "SECRETVALUE-$n" >> "$S/valid"
    printf '{"data":{"secret_id":"SECRETVALUE-%s","secret_id_accessor":"ACC-%s"}}\n' "$n" "$n" ;;
  "write -field=token auth/approle/login "*)
    sid_file="${args##*secret_id=@}"
    grep -qxF "$(cat "$sid_file" 2>/dev/null)" "$S/valid" 2>/dev/null && printf 'TOKEN' || exit 2 ;;
  "token lookup -field=policies")       printf '%s' "${FAKE_POLICIES:-[default vault-snapshot]}" ;;
  "token capabilities sys/storage/raft/snapshot") echo read ;;
  "token capabilities kv/data/services/vault-snapshots") echo read ;;
  "token capabilities kv/data/admin/probe")        echo "${FAKE_ADMIN:-deny}" ;;
  "token revoke -self")                 [ -z "${FAKE_REVOKE_FAIL:-}" ]; exit ;;
  "write auth/approle/role/vault-snapshot/secret-id-accessor/destroy secret_id_accessor="*)
    [ -z "${FAKE_DESTROY_FAIL:-}" ] || { echo "Error: permission denied" >&2; exit 2; }
    acc="${args##*accessor=}"; echo "$acc" >> "$S/destroyed"
    sid="SECRETVALUE-${acc#ACC-}"; grep -vxF "$sid" "$S/valid" > "$S/valid.new"; mv "$S/valid.new" "$S/valid" ;;
  *) echo "stub vault: unhandled: $args" >&2; exit 99 ;;
esac
STUB
chmod +x "$BIN/ssh" "$BIN/vault"

: > "$T/ca.crt"
export STATE PATH="$BIN:$PATH" VAULT_TOKEN=t VAULT_CACERT="$T/ca.crt" SNAP_CRED_DIR="$HOSTDIR"
SEED="$HERE/seed-vault-snapshot-approle.sh"
reset() { rm -rf "$HOSTDIR" "$STATE"; mkdir -p "$STATE"; : > "$STATE/valid"; : > "$STATE/destroyed"; unset FAKE_POLICIES FAKE_DESTROY_FAIL FAKE_ADMIN FAKE_REVOKE_FAIL; }
minted() { cat "$STATE/n" 2>/dev/null || echo 0; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
destroyed() { tr '\n' ' ' < "$STATE/destroyed" | sed 's/ $//'; }

echo "fresh seed"
reset
OUT="$("$SEED" 2>&1)"; rc=$?
eq "exits 0" 0 "$rc"
eq "role_id placed" ROLEID-123 "$(cat "$HOSTDIR/role_id")"
eq "secret_id mode" 600 "$(mode "$HOSTDIR/secret_id")"
eq "role_id mode" 600 "$(mode "$HOSTDIR/role_id")"
eq "directory mode" 700 "$(mode "$HOSTDIR")"
eq "secret_id placed" SECRETVALUE-1 "$(cat "$HOSTDIR/secret_id")"
case "$OUT" in *SECRETVALUE*) bad "output hides the secret_id" "no match" "secret_id printed" ;; *) ok "output hides the secret_id" ;; esac
case "$OUT" in *"accessor ACC-1"*) ok "output names the accessor" ;; *) bad "output names the accessor" "ACC-1" "$OUT" ;; esac
case "$OUT" in *"login=ok policies=[default vault-snapshot] snapshot=read minio_creds=read admin=deny"*) ok "proof line printed" ;; *) bad "proof line printed" "login=ok ..." "$OUT" ;; esac

echo "re-run changes nothing"
OUT="$("$SEED" 2>&1)"; rc=$?
eq "exits 0" 0 "$rc"
eq "no second mint" 1 "$(minted)"
case "$OUT" in *"Nothing to do"*) ok "says nothing to do" ;; *) bad "says nothing to do" "Nothing to do" "$OUT" ;; esac

echo "rotate"
OUT="$("$SEED" --rotate 2>&1)"; rc=$?
eq "exits 0" 0 "$rc"
eq "new secret_id placed" SECRETVALUE-2 "$(cat "$HOSTDIR/secret_id")"
eq "old accessor destroyed" ACC-1 "$(destroyed)"
[ ! -e "$HOSTDIR/secret_id_accessor.old" ] && ok "no .old record left" || bad "no .old record left" absent present
eq "accessor file holds the new one" ACC-2 "$(cat "$HOSTDIR/secret_id_accessor")"

echo "rotate when the destroy fails"
export FAKE_DESTROY_FAIL=1
"$SEED" --rotate >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "exits non-zero" || bad "exits non-zero" "non-zero" "$rc"
eq "old accessor recorded for retry" ACC-2 "$(cat "$HOSTDIR/secret_id_accessor.old" 2>/dev/null)"
unset FAKE_DESTROY_FAIL
"$SEED" >/dev/null 2>&1; rc=$?
eq "next run retries and exits 0" 0 "$rc"
[ ! -e "$HOSTDIR/secret_id_accessor.old" ] && ok ".old record cleared" || bad ".old record cleared" absent present
eq "retry destroyed the recorded accessor" "ACC-1 ACC-2" "$(destroyed)"

echo "a failed proof leaves nothing that can log in"
reset
export FAKE_POLICIES='[default vault-snapshot extra]'
"$SEED" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "exits non-zero" || bad "exits non-zero" "non-zero" "$rc"
[ ! -e "$HOSTDIR/secret_id" ] && [ ! -e "$HOSTDIR/role_id" ] && ok "files removed from the host" || bad "files removed from the host" absent present
eq "secret_id destroyed" ACC-1 "$(destroyed)"
reset
export FAKE_ADMIN=read
"$SEED" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "a token that reads kv/admin fails the proof" || bad "a token that reads kv/admin fails the proof" "non-zero" "$rc"

echo "existing files that do not log in"
reset
mkdir -p "$HOSTDIR"; printf 'ROLEID-123' > "$HOSTDIR/role_id"; printf 'STALE' > "$HOSTDIR/secret_id"
"$SEED" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "refuses without --rotate" || bad "refuses without --rotate" "non-zero" "$rc"
eq "mints nothing" 0 "$(minted)"
"$SEED" --rotate >/dev/null 2>&1; rc=$?
eq "--rotate replaces them" 0 "$rc"
eq "new secret_id placed" SECRETVALUE-1 "$(cat "$HOSTDIR/secret_id")"

echo "Vault token rejected"
reset
FAKE_TOKEN_BAD=1 "$SEED" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "exits non-zero" || bad "exits non-zero" "non-zero" "$rc"
eq "mints nothing" 0 "$(minted)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
