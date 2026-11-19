#!/usr/bin/env bash
# test-authentik-sync.sh — drive environments/authentik/files/authentik-sync.sh against fake aws,
# docker and systemctl commands (PET-932). The host gate is what this proves: the stack never
# starts without a restored copy, a failed restore leaves no marker, a refused copy changes
# nothing, and a bad digest stops the run. Each case prints what it checked. Any failure exits 1.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SYNC="$PWD/environments/authentik/files/authentik-sync.sh"
[ -f "$SYNC" ] || { echo "FAIL: $SYNC is missing"; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
FAKE="$ROOT/bin"; mkdir -p "$FAKE"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok: $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

# ── Fakes ──────────────────────────────────────────────────────────────────────────────────────
# aws: s3 and ssm against directories. $FAKE_S3/<key> is the bucket, $FAKE_SSM/<name> a parameter.
cat > "$FAKE/aws" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
key_of() { printf '%s' "${1#s3://*/}"; }
case "$1 $2" in
  "s3 sync") mkdir -p "$4"; cp -R "$FAKE_S3/$(key_of "$3")." "$4" ;;
  "s3 cp")
    src="$3"; dst="$4"
    if [ "${src#s3://}" != "$src" ]; then
      f="$FAKE_S3/$(key_of "$src")"; [ -f "$f" ] || { echo "fatal error: 404 $src" >&2; exit 1; }
      if [ "$dst" = - ]; then cat "$f"; else cp "$f" "$dst"; fi
    else
      f="$FAKE_S3/$(key_of "$dst")"; mkdir -p "$(dirname "$f")"; cp "$src" "$f"
    fi ;;
  "s3api head-object") k=""; while [ $# -gt 0 ]; do [ "$1" = --key ] && k="$2"; shift; done; [ -f "$FAKE_S3/$k" ] ;;
  "ssm get-parameter")
    n=""; while [ $# -gt 0 ]; do [ "$1" = --name ] && n="$2"; shift; done
    f="$FAKE_SSM/$(basename "$n")"
    [ -f "$f" ] || { echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2; exit 254; }
    cat "$f" ;;
  *) echo "fake aws: unhandled $*" >&2; exit 2 ;;
esac
SH
# docker: logs every compose call. exec answers the restore checks; FAIL_RESTORE=1 fails pg_restore.
cat > "$FAKE/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  inspect) echo healthy; exit 0 ;;
  compose) ;;
  *) exit 0 ;;
esac
all="$*"
case "$all" in
  *pg_restore*) cat > /dev/null; [ "${FAIL_RESTORE:-0}" = 1 ] && exit 1; exit 0 ;;
  *information_schema*) echo 120 ;;
  *authentik_core_user*) echo 3 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/systemctl"
chmod +x "$FAKE"/*

# ── Fixture ────────────────────────────────────────────────────────────────────────────────────
fresh() { # $1 ACCEPT_RESTORE value
  CASE="$ROOT/case$((PASS + FAIL))-$RANDOM"
  export FAKE_S3="$CASE/s3" FAKE_SSM="$CASE/ssm" DOCKER_LOG="$CASE/docker.log"
  export AUTHENTIK_DIR="$CASE/opt" UNIT_DIR="$CASE/units" APP_UID="$(id -u)"
  mkdir -p "$FAKE_S3/config" "$FAKE_SSM" "$AUTHENTIK_DIR/bin" "$UNIT_DIR"
  : > "$DOCKER_LOG"
  echo "services: {}" > "$FAKE_S3/config/docker-compose.yml"
  cp "$SYNC" "$FAKE_S3/config/authentik-sync.sh"
  printf '#!/bin/bash\nexit 0\n' > "$FAKE_S3/config/authentik-backup.sh"
  settings "$1"
}
settings() { printf 'BUCKET=b\nPARAM_PREFIX=/petedio-authentik\nAWS_REGION=us-east-2\nACCEPT_RESTORE=%s\n' "$1" > "$FAKE_S3/config/settings.env"; }
seed_secrets() {
  printf 'AUTHENTIK_SECRET_KEY=fake\nPG_PASS=fake\n' > "$FAKE_SSM/env"
  echo "fake-token" > "$FAKE_SSM/tunnel_token"
}
offer_copy() { # $1 stamp, $2 "bad" to corrupt the dump digest
  mkdir -p "$FAKE_S3/migrate" "$CASE/media-src"
  echo "dump $1" > "$FAKE_S3/migrate/authentik.dump"
  echo "icon $1" > "$CASE/media-src/icon.png"
  tar -czf "$FAKE_S3/migrate/media.tar.gz" -C "$CASE/media-src" .
  d="$(sha256sum "$FAKE_S3/migrate/authentik.dump" | cut -d' ' -f1)"
  [ "${2:-}" = bad ] && d="0000"
  printf '%s %s %s\n' "$1" "$d" "$(sha256sum "$FAKE_S3/migrate/media.tar.gz" | cut -d' ' -f1)" > "$FAKE_S3/migrate/READY"
}
run() { # prints the exit code; output goes to $CASE/out
  set +e
  PATH="$FAKE:$PATH" BUCKET=b AWS_REGION=us-east-2 bash "$SYNC" > "$CASE/out" 2>&1
  echo $?
  set -e
}
started()  { grep -q -- '--remove-orphans' "$DOCKER_LOG"; }
stamp()    { cat "$AUTHENTIK_DIR/state/restored-stamp" 2>/dev/null || true; }
says()     { grep -q -- "$1" "$CASE/out"; }

echo "case 1: no env parameter"
fresh true
rc="$(run)"
[ "$rc" = 0 ] && says "waiting: /petedio-authentik/env" && ! started && ok "exit 0, waits, stack not started" || bad "rc=$rc; $(tail -n 2 "$CASE/out")"

echo "case 2: secrets but no copy"
fresh true; seed_secrets
rc="$(run)"
[ "$rc" = 0 ] && says "waiting: no database copy" && ! started && [ -z "$(stamp)" ] && ok "exit 0, waits, no marker, stack not started" || bad "rc=$rc; $(tail -n 2 "$CASE/out")"

echo "case 3: a good copy, then a failed second restore, then the restore closed"
fresh true; seed_secrets; offer_copy S1
rc="$(run)"
[ "$rc" = 0 ] && [ "$(stamp)" = S1 ] && started && [ -f "$AUTHENTIK_DIR/media/icon.png" ] && ok "copy S1 restored, media extracted, stack started" || bad "rc=$rc stamp=$(stamp); $(tail -n 3 "$CASE/out")"
[ "$(jq -r .phase "$FAKE_S3/backups/status.json")" = ok ] && [ "$(jq -r .restored_stamp "$FAKE_S3/backups/status.json")" = S1 ] && ok "status.json published with phase ok and stamp S1" || bad "status.json: $(cat "$FAKE_S3/backups/status.json" 2>/dev/null)"
offer_copy S2; : > "$DOCKER_LOG"
rc="$(FAIL_RESTORE=1 run)"
[ "$rc" != 0 ] && [ -z "$(stamp)" ] && ! started && ok "failed restore exits $rc and leaves no marker" || bad "rc=$rc stamp=$(stamp)"
settings false; : > "$DOCKER_LOG"
rc="$(run)"
[ "$rc" = 0 ] && says "refused" && says "waiting: no database copy" && ! started && ok "after a failed restore, a closed restore keeps the stack down" || bad "rc=$rc started=$(started && echo yes || echo no); $(tail -n 3 "$CASE/out")"

echo "case 4: a copy offered while the restore is closed"
fresh false; seed_secrets; offer_copy S1
rc="$(run)"
[ "$rc" = 0 ] && says "refused" && ! started && [ -z "$(stamp)" ] && ok "refused, no marker, stack not started" || bad "rc=$rc; $(tail -n 3 "$CASE/out")"

echo "case 5: a copy whose digest does not match"
fresh true; seed_secrets; offer_copy S1 bad
rc="$(run)"
[ "$rc" = 1 ] && says "does not match its READY digest" && ! started && [ -z "$(stamp)" ] && ok "exit 1, no marker, stack not started" || bad "rc=$rc; $(tail -n 3 "$CASE/out")"

echo "case 6: a live host with the restore closed ignores a later copy"
fresh true; seed_secrets; offer_copy S1
rc="$(run)"; settings false; offer_copy S2; : > "$DOCKER_LOG"
rc="$(run)"
[ "$rc" = 0 ] && says "refused" && [ "$(stamp)" = S1 ] && started && ! grep -q dropdb "$DOCKER_LOG" && ok "keeps S1, drops nothing, stack runs" || bad "rc=$rc stamp=$(stamp); $(tail -n 3 "$CASE/out")"

echo "test-authentik-sync: $PASS passed, $FAIL failed, across 6 cases."
[ "$FAIL" -eq 0 ] && [ "$PASS" -eq 9 ] || { echo "FAIL: expected 9 checks to pass."; exit 1; }
