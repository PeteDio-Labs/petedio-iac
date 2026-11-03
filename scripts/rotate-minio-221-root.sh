#!/usr/bin/env bash
# rotate-minio-221-root.sh — change the MinIO ROOT password on LXC 221 and record it in Vault
# at kv/iac/minio-root (PET-795).
#
# WHY: the root password leaked into a Mac session transcript on 2026-11-02. seed-minio-221.sh
# only copies an existing credential into Vault; it cannot change MinIO's own password. This
# script changes it.
#
# WHAT IT DOES, in order. Each phase reports what it examined.
#   1. Reads the current root user and password from /etc/default/minio on 221, over SSH.
#   2. Reads kv/iac/minio-root (version, field names). Proves the password that MinIO runs
#      with authenticates.
#   3. On 221: generates a new password with python3 secrets (the value never reaches a log),
#      rewrites only the MINIO_ROOT_PASSWORD line of the env file atomically, restarts MinIO,
#      waits for /minio/health/ready, and refreshes the on-host mc alias `local`. A restart
#      that does not become ready restores the old file and restarts again.
#   4. From this machine, over the LAN: proves the new password works and the old one fails.
#      "Fails" counts only after "works" has shown MinIO is reachable.
#   5. Writes kv/iac/minio-root with check-and-set (patch -cas=<version read in phase 2) and
#      reads it back. The root_user field and every other field stay as they were.
#   6. Proves the tfstate service account in kv/iac/minio still works (service accounts hold
#      their own keys, so a root change leaves them valid).
#   7. Clears the pending marker on 221 and, when $MINIO_CREDS_FILE exists, replaces its
#      password line so the exposed value does not stay on disk.
#
# IDEMPOTENT AND RESUMABLE. Phase 3 leaves /root/.minio-rotation-pending on 221 until phase 5
# succeeds. The marker holds the sha256 of the old password. A run that finds a marker whose hash
# differs from the env file's password resumes at phase 4 and rotates nothing again. A run with no marker rotates.
#
# ORDER: run it once, now. Nothing needs to change first. MinIO is down for the restart
# (about 5 seconds). Do not run a terraform apply at the same time: the state backend is on
# this host. The Terraform state backend uses the tfstate service account (kv/iac/minio), not
# this credential. After the run, the convergence check in docs/runbooks/host-steps.md reports
# no change to /etc/default/minio, because the role renders the same line.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#   SSH:         root@192.168.50.221 with ~/.ssh/id_ed25519_ansible (override $MINIO_SSH_KEY).
#   Local tools: vault, mc, ssh, curl, python3.
#
# Usage:
#   ./scripts/rotate-minio-221-root.sh --check    # read-only: examine and report, change nothing
#   ./scripts/rotate-minio-221-root.sh            # rotate
#   ./scripts/rotate-minio-221-root.sh --no-creds-file   # rotate, but leave $MINIO_CREDS_FILE alone
#
# Exit codes: 0 done and every proof passed; 1 stopped on an error; 2 bad usage;
# 3 rotated and recorded, but a follow-up proof failed (read the summary).
# No value is printed, passed in argv, or written to disk except /etc/default/minio on 221.
set -euo pipefail
umask 077

CHECK=0
UPDATE_FILE=1
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --no-creds-file) UPDATE_FILE=0 ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_HOST="${MINIO_HOST:-192.168.50.221}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://$MINIO_HOST:9000}"
MINIO_SSH_KEY="${MINIO_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
MINIO_CREDS_FILE="${MINIO_CREDS_FILE:-$HOME/petedio/.secrets/minio-221.txt}"
ROOT_PATH="kv/iac/minio-root"
STATE_PATH="kv/iac/minio"
STATE_BUCKET="tfstate"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault mc ssh curl python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FOLLOWUP_FAILED=0
followup_fail(){ printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2; FOLLOWUP_FAILED=1; }

# --- SSH to 221 ----------------------------------------------------------------------------
[ -r "$MINIO_SSH_KEY" ] || die "no SSH key at $MINIO_SSH_KEY. Set MINIO_SSH_KEY."
# rsh REMOTE-COMMAND reads a script on stdin. Nothing secret goes in argv.
rsh(){ ssh -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
         -i "$MINIO_SSH_KEY" "root@$MINIO_HOST" "$@"; }

# Read-only: prints USER=…, PASS=…, PENDING=0|1 for the first line it cannot misread. The last
# assignment in the file wins, as it does for systemd.
REMOTE_STATE='python3 - <<"PY"
import os, re
text = open("/etc/default/minio").read()
def last(key):
    v = None
    for line in text.splitlines():
        m = re.match(r"^\s*" + key + r"=(.*)$", line)
        if m:
            v = m.group(1).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"\x27":
                v = v[1:-1]
    return v
u, p = last("MINIO_ROOT_USER"), last("MINIO_ROOT_PASSWORD")
if not u or not p:
    raise SystemExit("MISSING")
print("USER=" + u)
print("PASS=" + p)
mark = "/root/.minio-rotation-pending"
print("PENDING=" + (open(mark).read().strip() or "unknown" if os.path.exists(mark) else "none"))
PY'

REMOTE_ROTATE='set -euo pipefail
umask 077
ENVF=/etc/default/minio
MARK=/root/.minio-rotation-pending
OLD="$(cat "$ENVF")"
NEWPW="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
# Replace only the password line. Keep owner, group and mode. Swap the file atomically.
# The marker holds the sha256 of the old password and exists before the file changes, so a
# run that dies mid-way can tell a rotated file from an untouched one.
NEWPW="$NEWPW" python3 - <<"PY"
import hashlib, os, re
f = "/etc/default/minio"
st = os.stat(f)
text = open(f).read()
m0 = re.search(r"(?m)^\s*MINIO_ROOT_PASSWORD=(.*)$", text)
if not m0:
    raise SystemExit("no MINIO_ROOT_PASSWORD line")
mfd = os.open("/root/.minio-rotation-pending", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(mfd, "w") as mh:
    v0 = m0.group(1).strip()
    if len(v0) >= 2 and v0[0] == v0[-1] and v0[0] in "\"\x27":
        v0 = v0[1:-1]
    mh.write(hashlib.sha256(v0.encode()).hexdigest())
new, n = re.subn(r"(?m)^(\s*MINIO_ROOT_PASSWORD=).*$", lambda m: m.group(1) + os.environ["NEWPW"], text)
if n != 1:
    raise SystemExit("expected exactly one MINIO_ROOT_PASSWORD line, found %d" % n)
tmp = f + ".rot"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write(new)
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o7777)
os.replace(tmp, f)
PY
rollback() {
  printf "%s\n" "$OLD" > "$ENVF.rot"
  chown --reference="$ENVF" "$ENVF.rot"; chmod --reference="$ENVF" "$ENVF.rot"
  mv "$ENVF.rot" "$ENVF"; rm -f "$MARK"
  systemctl restart minio || true
  echo "ROLLED_BACK" >&2
}
if ! systemctl restart minio; then rollback; exit 1; fi
ok=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/ready; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != 1 ]; then rollback; exit 1; fi
echo "restarted, and /minio/health/ready answers" >&2
printf "NEWPASS=%s\n" "$NEWPW"'

# Refresh the on-host mc alias `local` from the env file, in every mode that follows a restart.
# The keys go in on stdin, never argv. Prints OK, SKIPPED (no mc on the host) or FAILED.
REMOTE_ALIAS='set -euo pipefail
if [ ! -x /usr/local/bin/mc ]; then echo SKIPPED; exit 0; fi
U="$(sed -n "s/^[[:space:]]*MINIO_ROOT_USER=//p" /etc/default/minio | tail -1)"
P="$(sed -n "s/^[[:space:]]*MINIO_ROOT_PASSWORD=//p" /etc/default/minio | tail -1)"
if printf "%s\n%s\n" "$U" "$P" | /usr/local/bin/mc alias set local http://127.0.0.1:9000 >/dev/null 2>&1; then echo OK; else echo FAILED; fi'

REMOTE_RESTART='set -euo pipefail
systemctl restart minio
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/ready; then echo ready; exit 0; fi
  sleep 2
done
exit 1'

# --- mc, with keys on stdin ------------------------------------------------------------------
MCCFG="$TMP/mc"; mkdir -p "$MCCFG"
m(){ mc --config-dir "$MCCFG" "$@"; }
# auth_ok USER PASS answers with its exit status: 0 MinIO accepted the pair, 1 MinIO rejected
# it (the error names a bad access key or a signature mismatch), 2 anything else: a reset, a
# timeout or a local mc failure. A caller counts only 1 as a rejection (Codex, PET-795).
auth_ok(){
  local out rc=0
  out="$(printf '%s\n%s\n' "$1" "$2" | m alias set probe "$MINIO_ENDPOINT" --api s3v4 --path auto 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then out="$(m ls probe 2>&1)" || rc=$?; fi
  [ "$rc" = 0 ] && return 0
  if printf '%s' "$out" | grep -qiE 'InvalidAccessKeyId|SignatureDoesNotMatch|Access Key Id you provided|signature we calculated|InvalidAccessKey'; then
    return 1
  fi
  return 2
}
# auth_state USER PASS prints accepted, rejected or unknown, and never fails.
auth_state(){
  local rc=0
  auth_ok "$1" "$2" || rc=$?
  case "$rc" in 0) echo accepted ;; 1) echo rejected ;; *) echo unknown ;; esac
}

# --- Vault helpers (the vault-seed skill, sections 3 and 4) ----------------------------------
snap(){
  local err
  if SNAPSHOT="$(vault kv get -format=json "$1" 2>/dev/null)"; then
    VERSION="$(SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
d = json.loads(os.environ["SNAPSHOT"])["data"]
print("deleted" if d.get("data") is None else d["metadata"]["version"])')" || die "could not parse the read of $1."
    [ "$VERSION" != "deleted" ] || die "the current version of $1 is deleted. Undelete or destroy it by hand, then run this again."
  elif err="$(vault kv metadata get "$1" 2>&1 >/dev/null)"; then
    die "$1 has metadata, but the token cannot read its data. Check the token's policy."
  else
    case "$err" in
      "No value found at "*) VERSION=0; SNAPSHOT='{}' ;;
      *) die "Vault failed the read of $1: $(printf '%s' "$err" | tr -s '\n\t' '  ' | cut -c1-200)" ;;
    esac
  fi
}
field(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(d.get(sys.argv[1], ""))' "$1"; }
fieldnames(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(" ".join(sorted(d)))'; }

# --- Phase 0: Vault token ---------------------------------------------------------------------
step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] \
  || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'. Export VAULT_TOKEN, then run this again."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 \
  || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
echo "  reachable, and the token is valid"

# --- Phase 1: what 221 runs with ----------------------------------------------------------------
step "MinIO on $MINIO_HOST: current state"
curl -fsS -o /dev/null --max-time 8 "$MINIO_ENDPOINT/minio/health/ready" \
  || die "$MINIO_ENDPOINT/minio/health/ready does not answer. Is this machine on the .50 LAN, and is MinIO up?"
echo "  $MINIO_ENDPOINT answers /minio/health/ready"
STATE="$(rsh "$REMOTE_STATE")" || die "could not read /etc/default/minio on $MINIO_HOST over SSH (key $MINIO_SSH_KEY)."
ENV_USER="$(printf '%s\n' "$STATE" | sed -n 's/^USER=//p')"
ENV_PASS="$(printf '%s\n' "$STATE" | sed -n 's/^PASS=//p')"
PENDING="$(printf '%s\n' "$STATE" | sed -n 's/^PENDING=//p')"
unset STATE
[ -n "$ENV_USER" ] && [ -n "$ENV_PASS" ] && [ -n "$PENDING" ] \
  || die "/etc/default/minio on $MINIO_HOST does not hold both MINIO_ROOT_USER and MINIO_ROOT_PASSWORD."
ENV_SHA="$(P="$ENV_PASS" python3 -c 'import hashlib,os;print(hashlib.sha256(os.environ["P"].encode()).hexdigest())')"
PROVEN=0
case "$PENDING" in
  none) MARKER_NOTE="none" ;;
  proven:*) MARKER_NOTE="present, old-password proof recorded"; PROVEN=1; PENDING="${PENDING#proven:}" ;;
  *) MARKER_NOTE="present" ;;
esac
echo "  env file: user length ${#ENV_USER}, password length ${#ENV_PASS}, pending marker: $MARKER_NOTE"

# --- Phase 2: what Vault holds ------------------------------------------------------------------
step "$ROOT_PATH"
snap "$ROOT_PATH"
VAULT_USER="$(field root_user)"; VAULT_PASS="$(field root_password)"; V_FIELDS="$(fieldnames)"; V_VERSION="$VERSION"
echo "  version $V_VERSION, fields: ${V_FIELDS:-none}"
if [ -n "$VAULT_USER" ] && [ "$VAULT_USER" != "$ENV_USER" ]; then
  die "root_user in Vault differs from MINIO_ROOT_USER on $MINIO_HOST. Resolve that by hand: this script changes the password only."
fi

ENV_OK=0; VAULT_OK=0
A="$(auth_state "$ENV_USER" "$ENV_PASS")"
[ "$A" != unknown ] || die "could not tell whether MinIO accepts the env-file password: the check failed for a reason other than a rejection."
[ "$A" = accepted ] && ENV_OK=1
if [ -n "$VAULT_PASS" ] && [ "$VAULT_PASS" != "$ENV_PASS" ]; then
  A="$(auth_state "$ENV_USER" "$VAULT_PASS")"
  [ "$A" != unknown ] || die "could not tell whether MinIO accepts the Vault password: the check failed for a reason other than a rejection."
  [ "$A" = accepted ] && VAULT_OK=1
fi
echo "  env-file password authenticates: $ENV_OK"
if [ -n "$VAULT_PASS" ] && [ "$VAULT_PASS" != "$ENV_PASS" ]; then
  echo "  Vault password differs from the env file; it authenticates: $VAULT_OK"
elif [ -n "$VAULT_PASS" ]; then
  echo "  Vault password equals the env file's"
else
  echo "  Vault holds no root_password"
fi

# Decide: ROTATE (phase 3), RESUME (skip to phase 4), or RESTART-THEN-RESUME.
# A marker whose hash differs from the env file's means the file already holds a new password.
ROTATED=0
if [ "$PENDING" != "none" ] && [ "$PENDING" != "$ENV_SHA" ]; then ROTATED=1; fi
if [ "$ROTATED" = "1" ] && [ "$ENV_OK" = "1" ]; then
  MODE=resume
elif [ "$ROTATED" = "1" ] && [ "$ENV_OK" = "0" ] && [ "$VAULT_OK" = "1" ]; then
  MODE=restart-resume
elif [ "$ENV_OK" = "1" ]; then
  MODE=rotate
else
  die "the env-file password does not authenticate and no pending rotation explains it. Look at 'systemctl status minio' on $MINIO_HOST."
fi
echo "  plan: $MODE"
if [ "$CHECK" = "1" ]; then
  step "Check only"
  echo "  examined: the health endpoint, /etc/default/minio (lengths only), $ROOT_PATH (version and field names), and two authentications."
  echo "  changed: nothing. Run again without --check to $MODE."
  exit 0
fi

OLD_PASS="$ENV_PASS"; NEW_PASS=""
# The previous password for the "old fails" proof: the env file's before a rotation, else
# whatever Vault held. A resume knows only what Vault held, and says so.
case "$MODE" in
  rotate)
    step "Rotate on $MINIO_HOST"
    OUT="$(rsh "$REMOTE_ROTATE")" || die "the rotation on $MINIO_HOST failed. If stderr said ROLLED_BACK, the old file is back and nothing changed. Otherwise check 'systemctl status minio' there."
    NEW_PASS="$(printf '%s\n' "$OUT" | sed -n 's/^NEWPASS=//p')"; unset OUT
    [ -n "$NEW_PASS" ] || die "the rotation printed no new password. The env file on $MINIO_HOST may hold one: re-run this script, which resumes when the pending marker exists."
    echo "  new password: ${#NEW_PASS} characters"
    ;;
  restart-resume)
    step "Restart MinIO on $MINIO_HOST (the env file was changed, MinIO was not restarted)"
    rsh "$REMOTE_RESTART" >/dev/null || die "MinIO did not become ready after the restart."
    NEW_PASS="$ENV_PASS"; OLD_PASS="$VAULT_PASS"
    ;;
  resume)
    step "Resume a rotation recorded on $MINIO_HOST"
    NEW_PASS="$ENV_PASS"; OLD_PASS="$VAULT_PASS"
    echo "  the env-file password works and Vault does not hold it"
    ;;
esac
unset ENV_PASS

# --- Phase 4: prove new works, old fails ---------------------------------------------------------
step "Prove the passwords against $MINIO_ENDPOINT"
[ "$(auth_state "$ENV_USER" "$NEW_PASS")" = accepted ] \
  || die "the new password is not accepted. $MINIO_HOST holds it in /etc/default/minio; re-run this script."
echo "  the new password authenticates"
if [ "$PROVEN" = "1" ]; then
  echo "  the old password's rejection was proven by the earlier run (recorded on $MINIO_HOST)"
elif [ -n "$OLD_PASS" ] && [ "$OLD_PASS" != "$NEW_PASS" ]; then
  case "$(auth_state "$ENV_USER" "$OLD_PASS")" in
    rejected) echo "  the old password is rejected (MinIO named a bad key or a signature mismatch)" ;;
    accepted) die "the old password still authenticates after the restart." ;;
    *) followup_fail "the old-password check failed for a reason other than a rejection, so its rejection is unproven" ;;
  esac
else
  echo "  the old password is unknown to this run, so its rejection is unproven"
  followup_fail "old password not proven rejected"
fi
if [ -f "$MINIO_CREDS_FILE" ]; then
  FP="$(python3 "$SCRIPT_DIR/minio-cred.py" "$MINIO_CREDS_FILE" ROOT_PASSWORD 2>/dev/null || true)"
  if [ -n "$FP" ] && [ "$FP" != "$NEW_PASS" ]; then
    case "$(auth_state "$ENV_USER" "$FP")" in
      rejected) echo "  the password in $MINIO_CREDS_FILE is rejected" ;;
      accepted) followup_fail "the password in $MINIO_CREDS_FILE still authenticates" ;;
      *) followup_fail "the check of the password in $MINIO_CREDS_FILE failed for a reason other than a rejection" ;;
    esac
  fi
  unset FP
fi
# Refresh the on-host mc alias in every mode, so a resumed run does not leave the exposed
# password in /root/.mc/config.json on the host.
case "$(rsh "$REMOTE_ALIAS" 2>/dev/null || echo FAILED)" in
  OK) echo "  refreshed the on-host mc alias local" ;;
  SKIPPED) echo "  no mc on $MINIO_HOST, so there is no on-host alias to refresh" ;;
  *) followup_fail "could not refresh the on-host mc alias local on $MINIO_HOST. Re-run configure-minio.yml." ;;
esac
# Record that the proof is done, so an interruption before the Vault write completes does not
# turn the next run's proof into a failure. The marker keeps the old password's sha256.
if [ "$PROVEN" != "1" ] && [ -n "$OLD_PASS" ] && [ "$OLD_PASS" != "$NEW_PASS" ] && [ "$FOLLOWUP_FAILED" = "0" ]; then
  OLD_SHA="$(P="$OLD_PASS" python3 -c 'import hashlib,os;print(hashlib.sha256(os.environ["P"].encode()).hexdigest())')"
  printf 'proven:%s' "$OLD_SHA" | rsh 'cat > /root/.minio-rotation-pending' \
    || followup_fail "could not record the proof on $MINIO_HOST"
fi

# --- Phase 5: Vault, check-and-set, read back ----------------------------------------------------
step "Write $ROOT_PATH"
snap "$ROOT_PATH"
[ "$VERSION" = "$V_VERSION" ] \
  || die "$ROOT_PATH changed from version $V_VERSION to $VERSION since the read. Another writer touched it. Re-run this script: it resumes."
if [ "$(field root_password)" = "$NEW_PASS" ]; then
  echo "  Vault already holds the new password (a previous run wrote it). Writing nothing."
elif [ "$VERSION" = "0" ]; then
  NU="$ENV_USER" NP="$NEW_PASS" python3 -c '
import json, os
print(json.dumps({"root_user": os.environ["NU"], "root_password": os.environ["NP"]}))' \
    | vault kv put -cas=0 "$ROOT_PATH" - >/dev/null \
    || die "the first write to $ROOT_PATH failed. The new password is in /etc/default/minio on $MINIO_HOST; re-run this script."
else
  NP="$NEW_PASS" python3 -c '
import json, os
print(json.dumps({"root_password": os.environ["NP"]}))' \
    | vault kv patch -cas="$VERSION" "$ROOT_PATH" - >/dev/null \
    || die "the check-and-set write to $ROOT_PATH failed, so Vault keeps what it held. The new password is in /etc/default/minio on $MINIO_HOST; re-run this script."
fi
snap "$ROOT_PATH"
[ "$(field root_password)" = "$NEW_PASS" ] || die "the read-back of $ROOT_PATH does not match the new password."
[ "$(field root_user)" = "$ENV_USER" ] || die "the read-back of $ROOT_PATH has a different root_user."
for f in $V_FIELDS; do
  [ -n "$(field "$f")" ] || die "the read-back of $ROOT_PATH lost the field $f."
done
echo "  now at version $VERSION, and the read-back matches (fields: $(fieldnames))"

# --- Phase 6: the state backend's service account -------------------------------------------------
step "State backend service account ($STATE_PATH)"
if snap_out="$(vault kv get -format=json "$STATE_PATH" 2>/dev/null)"; then
  SNAPSHOT="$snap_out"
  SA="$(field access_key)"; SS="$(field secret_key)"
  if [ -n "$SA" ] && [ -n "$SS" ] && auth_ok "$SA" "$SS" \
     && m ls "probe/$STATE_BUCKET/" >/dev/null 2>&1; then
    echo "  the tfstate service account still lists $STATE_BUCKET"
  else
    followup_fail "the service account in $STATE_PATH no longer reaches $STATE_BUCKET. Run scripts/reseed-minio-vault.sh."
  fi
  unset SS
else
  followup_fail "this token cannot read $STATE_PATH, so the state backend's key is unproven"
fi

# --- Phase 7: clear the marker, retire the exposed copy --------------------------------------------
step "Clean up"
rsh 'rm -f /root/.minio-rotation-pending' || followup_fail "could not remove the pending marker on $MINIO_HOST. Remove /root/.minio-rotation-pending by hand."
echo "  removed the pending marker on $MINIO_HOST"
if [ "$UPDATE_FILE" = "1" ] && [ -f "$MINIO_CREDS_FILE" ]; then
  if NP="$NEW_PASS" F="$MINIO_CREDS_FILE" python3 - <<'PY'
import os, re, sys
f = os.environ["F"]
text = open(f, encoding="utf-8").read()
pat = re.compile(r"(?mi)^(\s*(?:export\s+)?(?:MINIO_)?ROOT_PASSWORD\s*[=:]\s*)(.*?)(\r?)$")
def sub(m):
    old = m.group(2)
    q = old[0] if len(old) >= 2 and old[0] == old[-1] and old[0] in "\"'" else ""
    return m.group(1) + q + os.environ["NP"] + q + m.group(3)
new, n = pat.subn(sub, text, count=1)
if n != 1:
    sys.exit(1)
tmp = f + ".rot"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(new)
os.replace(tmp, f)
os.chmod(f, 0o600)
PY
  then echo "  replaced the password line in $MINIO_CREDS_FILE (mode 600)"
  else followup_fail "could not find a ROOT_PASSWORD line in $MINIO_CREDS_FILE. Replace or delete the file by hand."
  fi
elif [ -f "$MINIO_CREDS_FILE" ]; then
  echo "  left $MINIO_CREDS_FILE alone (--no-creds-file). It still holds the exposed password. Delete it or replace the line."
else
  echo "  no $MINIO_CREDS_FILE on this machine. If another machine has a copy, replace or delete it there."
fi
unset NEW_PASS OLD_PASS VAULT_PASS

step "Summary"
echo "  examined: env file on $MINIO_HOST, $ROOT_PATH, the root password against $MINIO_ENDPOINT, the tfstate service account."
if [ "$FOLLOWUP_FAILED" = "1" ]; then
  echo "  The password is rotated and recorded in Vault, but a proof above failed. Read the FAIL lines." >&2
  exit 3
fi
echo "  The root password is rotated, recorded in Vault, and every proof passed."
echo "  Next: run the convergence check in docs/runbooks/host-steps.md, section 'Rotate the MinIO root password on 221'."
echo "  Then: comment on the PET item with the Vault version and the field names. Do not paste a value."
