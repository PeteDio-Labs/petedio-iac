#!/usr/bin/env bash
# claude-247-extra-vars.sh — check LXC 247's identities and write them as the extra-vars
# file configure-claude-code.yml takes (PET-515).
#
#   scripts/claude-247-extra-vars.sh <out.json>
#
# ⚠ EVERY INPUT COMES FROM THE ENVIRONMENT, NEVER FROM ARGV. `ps` on a shared machine reads
# argv, and four of these are App private keys. The only argument is the output path.
#
#   APP_ID INSTALL_ID APP_PEM                          kv/services/claude-loop     (REQUIRED)
#   PLANE_KEY                                          kv/services/plane           (REQUIRED)
#   MIRROR_APP_ID MIRROR_INSTALL_ID MIRROR_APP_PEM     kv/services/claude-workspace-mirror
#   VAULT_APP_ID VAULT_INSTALL_ID VAULT_APP_PEM        kv/services/claude-vault-push
#   CODE_APP_ID CODE_INSTALL_ID CODE_APP_PEM           kv/services/claude-code-push
#   PVE_TOKEN_ID PVE_TOKEN_SECRET PVE_ENDPOINT PVE_CA_PEM   kv/services/claude-247-pve
#   PLANE_BASE_URL PLANE_WORKSPACE PLANE_IDENTIFIER    optional, defaults below
#
# It has two callers, and they differ only in how they read Vault:
#   .github/workflows/ansible-claude-247.yml   the primary path. vault-action reads the fields
#                                              through the claude-247-deploy JWT role.
#   scripts/deploy-claude-247.sh               the fallback, from the operator's machine,
#                                              through the ansible AppRole.
# So this script needs no Vault CLI and no AppRole. The checks live here so that both paths
# refuse the same things with the same words. Keep them here; a copy in either caller drifts.
#
# ⚠ FOUR APPS, AND THEY MUST STAY FOUR. The loop's pushes to petedio-iac and opens PRs, the
# mirror's is read-only on petedio-workspace, the vault's pushes to petedio-vault, and the
# code-push App pushes to three code repositories and opens PRs there. Two of the six possible mix-ups are outright
# dangerous — the vault's App in the mirror's path hands a half-hourly ROOT timer a push
# credential, and the loop's App in the vault's path hands every session on 247 push and
# pull-request rights on petedio-iac. The code-push App in the mirror's path hands the same
# root timer a write credential. The checks below refuse all of them by App id, because
# telling the safe mix-ups from the dangerous ones at a glance is exactly the judgement an
# operator should not have to make at 03:00.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLANE_BASE_URL="${PLANE_BASE_URL:-http://192.168.50.235:8080}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-petedio}"
PLANE_IDENTIFIER="${PLANE_IDENTIFIER:-PET}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in python3 curl openssl; do command -v "$t" >/dev/null || die "$t not in PATH"; done
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  die "usage: $0 <out.json>. Every input comes from the environment."
fi
OUT="$1"

# An unset input reads the same as an empty one, which is what the checks below test for.
: "${APP_ID:=}" "${INSTALL_ID:=}" "${APP_PEM:=}" "${PLANE_KEY:=}"
: "${MIRROR_APP_ID:=}" "${MIRROR_INSTALL_ID:=}" "${MIRROR_APP_PEM:=}"
: "${VAULT_APP_ID:=}" "${VAULT_INSTALL_ID:=}" "${VAULT_APP_PEM:=}"
: "${CODE_APP_ID:=}" "${CODE_INSTALL_ID:=}" "${CODE_APP_PEM:=}"
: "${PVE_TOKEN_ID:=}" "${PVE_TOKEN_SECRET:=}" "${PVE_ENDPOINT:=}" "${PVE_CA_PEM:=}"

# ⚠ REFUSE TO LAND A CREDENTIAL WITH NOTHING TO CONSUME IT (PET-414).
#
# This is not hypothetical tidiness. It happened: PR #298 merged the identity half of the
# loop — this script, tasks/loop.yml, the broker — while the units, the tick script and
# tasks/loop-units.yml were still on an unmerged branch. Running this script against that
# tree would have installed sudo on a host that deliberately had none, written the sudoers
# grant, landed a GitHub App private key beside it, and installed NOTHING that uses any of
# it. Every session on the box would have gained a push/PR token and the loop would not
# have existed. That is worse than both deploying properly and not deploying.
#
# The generalisation is worth keeping after the ordering problem is gone: a script that
# lands a credential should check that the thing which consumes it is present. Here that
# check is cheap and exact, because the consumers are files in this repo.
for f in ansible/roles/claude-code/tasks/loop-units.yml \
         ansible/roles/claude-code/templates/claude-loop.service.j2 \
         ansible/roles/claude-code/templates/claude-loop.timer.j2 \
         scripts/claude-loop-tick.sh; do
  [ -f "$REPO_ROOT/$f" ] || die "$f is missing from this checkout.

  This tree has the loop's CREDENTIALS but not the loop. Landing the App key now would give
  every session on 247 a push/PR token with nothing to use it for. Merge the branch carrying
  the units and the tick script first, then re-run. See PET-414."
done

# The reverse of the same mistake: a tree new enough to have the units but old enough to
# still carry the sudoers grant means someone merged the halves out of order, or resurrected
# a file. Landing the key alongside that grant is the PET-408 bypass, live.
[ -f "$REPO_ROOT/ansible/roles/claude-code/templates/claude-loop-sudoers.j2" ] \
  && die "ansible/roles/claude-code/templates/claude-loop-sudoers.j2 exists in this checkout.

  PET-408 deleted it: the grant it renders belongs to the claude UID, which the loop's own
  \`claude -p\` session also holds. If it is back, something restored it — do not deploy
  until you know what."

# A PEM that survived a copy-paste as one line signs nothing, and openssl's complaint about
# it points at the signature, not the field. Check the shape here, where the fix is obvious.
check_pem() {
  local pem="$1" where="$2"
  printf '%s' "$pem" | grep -q -- "-----BEGIN .*PRIVATE KEY-----" \
    || die "app_pem in $where does not look like a PEM private key. Re-seed it with the .pem file GitHub gave you, newlines intact."
  [ "$(printf '%s' "$pem" | wc -l)" -ge 3 ] \
    || die "app_pem in $where is a single line — its newlines were lost on the way into Vault. Re-seed it."
}

step "Resolving the loop identity"
# No fallbacks and no placeholders, on purpose. Every one of these lands on the host as a
# 0400 file that LOOKS provisioned; a blank or guessed value would not fail here, it would
# fail at the first tick, at 03:00, in a unit nobody is watching.
[ -n "$APP_ID" ] || die "app_id missing from kv/services/claude-loop — seed it first (docs/runbooks/claude-loop.md)."
[ -n "$INSTALL_ID" ] || die "installation_id missing from kv/services/claude-loop."
[ -n "$APP_PEM" ] || die "app_pem missing from kv/services/claude-loop."
[ -n "$PLANE_KEY" ] || die "api_key missing from kv/services/plane — the same PAT CI uses."

check_pem "$APP_PEM" "kv/services/claude-loop"

# ⚠ These two MUST be different Apps' worth of care even though there is only one App here:
# app_id identifies the App, installation_id identifies its install on ONE repo. Swapping
# them mints nothing and reports a 404 that reads like a missing App.
printf 'loop: app %s, installation %s, pem %s bytes, plane PAT %s bytes\n' \
  "$APP_ID" "$INSTALL_ID" "${#APP_PEM}" "${#PLANE_KEY}"

step "Resolving the workspace mirror identity (PET-493)"
# OPTIONAL, and the asymmetry with the loop above is deliberate. 247 declares
# claude_workspace_mirror_enable permanently in host_vars, so this script has to stay
# runnable on a host whose mirror is already seeded and whose Vault path has not been
# written yet. All three fields absent is a supported state; SOME of them is not, because a
# half-written Vault path is the shape a failed seed leaves behind.

MIRROR_PRESENT=0
MIRROR_FOUND=0
for v in "$MIRROR_APP_ID" "$MIRROR_INSTALL_ID" "$MIRROR_APP_PEM"; do
  [ -n "$v" ] && MIRROR_FOUND=$((MIRROR_FOUND + 1))
done

if [ "$MIRROR_FOUND" -eq 3 ]; then
  MIRROR_PRESENT=1
elif [ "$MIRROR_FOUND" -gt 0 ]; then
  die "kv/services/claude-workspace-mirror is half-written: $MIRROR_FOUND of app_id, installation_id, app_pem are set.

  A partial path is what a failed seed leaves behind, and landing it would put a 0400 file on
  247 that looks provisioned and mints nothing. Re-run ./scripts/seed-workspace-mirror-vault.sh."
else
  warn "kv/services/claude-workspace-mirror is empty, so the mirror App is NOT being landed.

  Everything else in this run converges, and the play delivers petedio-workspace from
  whatever credentials are already on 247. If that repo has never been delivered, the play
  will converge and then FAIL at the end naming this as the step. To fix it, run
  ./scripts/seed-workspace-mirror-vault.sh and then this script again."
fi

if [ "$MIRROR_PRESENT" -eq 1 ]; then
  # ⚠ THE SAME APP IN BOTH PATHS IS THE ONE FAILURE THIS CANNOT BE ALLOWED TO PASS. The loop's
  # App carries contents:write and pull_requests:write. The mirror's broker runs as root from a
  # half-hourly timer. Pointing the second at the first would hand that timer a push credential
  # for petedio-iac — a strictly worse arrangement than the deploy key PET-493 replaced.
  [ "$MIRROR_APP_ID" != "$APP_ID" ] \
    || die "kv/services/claude-workspace-mirror and kv/services/claude-loop name the SAME App (id $APP_ID).

  They must be two Apps. The loop's can push and open PRs; the mirror's must be Contents and
  Metadata read-only on petedio-workspace alone. Seeding one into both paths gives a root
  timer a push credential. Create the second App and re-seed."

  # Same consumer-presence rule as the loop's above, applied to the mirror's half. A tree
  # without these files would take the App key and install nothing that reads it.
  for f in ansible/roles/claude-code/tasks/workspace-mirror.yml \
           ansible/roles/claude-code/templates/claude-workspace-mirror-broker.j2 \
           ansible/roles/claude-code/templates/claude-workspace-mirror-github.env.j2 \
           ansible/roles/claude-code/templates/claude-workspace-mirror.service.j2 \
           ansible/roles/claude-code/templates/claude-workspace-mirror.timer.j2; do
    [ -f "$REPO_ROOT/$f" ] || die "$f is missing from this checkout.

  This tree has the mirror's CREDENTIALS but not the mirror. Landing the App key now would
  put a private key on 247 with nothing that reads it. Merge the branch carrying the mirror
  role first, then re-run. See PET-414 and PET-493."
  done

  check_pem "$MIRROR_APP_PEM" "kv/services/claude-workspace-mirror"
  printf 'mirror: app %s, installation %s, pem %s bytes\n' \
    "$MIRROR_APP_ID" "$MIRROR_INSTALL_ID" "${#MIRROR_APP_PEM}"
fi

step "Resolving the vault push identity (PET-498)"
# OPTIONAL, for the same reason the mirror above is: 247 declares claude_vault_enable
# permanently in host_vars, so this script stays runnable against a host whose clone exists
# and whose Vault path has not been written yet. Three fields or none; some of them is a
# failed seed, not a state.
#
# ⚠ THIS IS THE ONE IDENTITY ON 247 THE SESSION USER CAN READ. The loop's key and the
# mirror's are 0400 root behind 0500 root brokers, because root is what uses them. This one
# is 0400 claude, because the thing that pushes IS the session. Every process running as
# `claude` on that host can therefore push to petedio-vault. That is the feature, and the App
# is what bounds it: one repository, contents:write and metadata:read, no pull requests.

VAULT_PRESENT=0
VAULT_FOUND=0
for v in "$VAULT_APP_ID" "$VAULT_INSTALL_ID" "$VAULT_APP_PEM"; do
  [ -n "$v" ] && VAULT_FOUND=$((VAULT_FOUND + 1))
done

if [ "$VAULT_FOUND" -eq 3 ]; then
  VAULT_PRESENT=1
elif [ "$VAULT_FOUND" -gt 0 ]; then
  die "kv/services/claude-vault-push is half-written: $VAULT_FOUND of app_id, installation_id, app_pem are set.

  A partial path is what a failed seed leaves behind, and landing it would put a 0400 file in
  the session user's home that looks provisioned and mints nothing. Re-run
  ./scripts/seed-claude-vault-app.sh."
else
  warn "kv/services/claude-vault-push is empty, so the vault App is NOT being landed.

  Everything else in this run converges, and the play leaves the petedio-vault clone as it
  found it. If that repo has never been delivered, the play will converge and then FAIL at the
  end naming this as the step. To fix it, run ./scripts/seed-claude-vault-app.sh and then this
  script again."
fi

if [ "$VAULT_PRESENT" -eq 1 ]; then
  # ⚠ THE OTHER TWO PAIRINGS, REFUSED HERE BECAUSE THIS BLOCK IS THE ONLY ONE HOLDING ALL
  # THREE IDS. The mirror's block above already refuses mirror == loop.
  [ "$VAULT_APP_ID" != "$APP_ID" ] \
    || die "kv/services/claude-vault-push and kv/services/claude-loop name the SAME App (id $APP_ID).

  The loop's App pushes to petedio-iac and opens pull requests, and this path's key is
  readable by every session on 247. Seeding one into both gives those sessions the loop's
  rights on petedio-iac. Create the vault's own App and re-seed."

  if [ "$MIRROR_PRESENT" -eq 1 ]; then
    [ "$VAULT_APP_ID" != "$MIRROR_APP_ID" ] \
      || die "kv/services/claude-vault-push and kv/services/claude-workspace-mirror name the SAME App (id $VAULT_APP_ID).

  The vault's App carries contents:write, and the mirror's broker runs as root from a
  half-hourly timer. Pointing that timer at a write credential is the arrangement PET-493
  was opened to remove. Create two Apps and re-seed."
  fi

  # Same consumer-presence rule the other two identities use: a tree that takes the key but
  # installs nothing that reads it leaves a private key on 247 doing nothing.
  for f in ansible/roles/claude-code/tasks/vault.yml \
           ansible/roles/claude-code/templates/claude-vault-broker.j2 \
           ansible/roles/claude-code/templates/claude-vault-github.env.j2; do
    [ -f "$REPO_ROOT/$f" ] || die "$f is missing from this checkout.

  This tree has the vault's CREDENTIALS but not the consumer. Landing the App key now would
  put a private key in the session user's home with nothing that reads it. Merge the branch
  carrying roles/claude-code's vault tasks first, then re-run. See PET-498."
  done

  check_pem "$VAULT_APP_PEM" "kv/services/claude-vault-push"
  printf 'vault: app %s, installation %s, pem %s bytes\n' \
    "$VAULT_APP_ID" "$VAULT_INSTALL_ID" "${#VAULT_APP_PEM}"
fi

step "Resolving the code-push identity (PET-507)"
# OPTIONAL, for the reason the vault block above gives: 247 declares claude_code_push_enable
# permanently in host_vars. Three fields or none; some of them is a failed seed, not a state.
#
# ⚠ THE SESSION USER CAN READ THIS KEY TOO, like the vault's. It reaches three repositories
# with push and pull-request rights. What bounds it is the App: no `workflows` permission, and
# a `main` on each repository that requires a review the App cannot give.

CODE_PRESENT=0
CODE_FOUND=0
for v in "$CODE_APP_ID" "$CODE_INSTALL_ID" "$CODE_APP_PEM"; do
  [ -n "$v" ] && CODE_FOUND=$((CODE_FOUND + 1))
done

if [ "$CODE_FOUND" -eq 3 ]; then
  CODE_PRESENT=1
elif [ "$CODE_FOUND" -gt 0 ]; then
  die "kv/services/claude-code-push is half-written: $CODE_FOUND of app_id, installation_id, app_pem are set.

  A partial path is what a failed seed leaves behind. Re-run ./scripts/seed-claude-code-app.sh."
else
  warn "kv/services/claude-code-push is empty, so the code-push App is NOT being landed.

  Everything else in this run converges, and the play leaves the three code clones' git config
  as it found it. To fix it, run ./scripts/seed-claude-code-app.sh and then this script again."
fi

if [ "$CODE_PRESENT" -eq 1 ]; then
  # Every pairing with the three other Apps, refused here because this block is the only one
  # that holds all four ids.
  [ "$CODE_APP_ID" != "$APP_ID" ] \
    || die "kv/services/claude-code-push and kv/services/claude-loop name the SAME App (id $APP_ID).

  The loop's key is root's on 247, and this path's key is readable by every session there.
  Create the code-push App as its own App and re-seed."

  if [ "$MIRROR_PRESENT" -eq 1 ]; then
    [ "$CODE_APP_ID" != "$MIRROR_APP_ID" ] \
      || die "kv/services/claude-code-push and kv/services/claude-workspace-mirror name the SAME App (id $CODE_APP_ID).

  The code-push App carries contents:write, and the mirror's broker runs as root from a
  half-hourly timer. Create two Apps and re-seed."
  fi

  if [ "$VAULT_PRESENT" -eq 1 ]; then
    [ "$CODE_APP_ID" != "$VAULT_APP_ID" ] \
      || die "kv/services/claude-code-push and kv/services/claude-vault-push name the SAME App (id $CODE_APP_ID).

  One App installed on four repositories would let a token narrowed for the vault reach code,
  and the other way round. Create two Apps and re-seed."
  fi

  for f in ansible/roles/claude-code/tasks/code-push.yml \
           ansible/roles/claude-code/templates/claude-code-push-broker.j2 \
           ansible/roles/claude-code/templates/claude-code-push-github.env.j2 \
           ansible/roles/claude-code/templates/claude-gh.j2; do
    [ -f "$REPO_ROOT/$f" ] || die "$f is missing from this checkout.

  This tree has the code-push CREDENTIALS but not the consumer. Landing the App key now would
  put a private key in the session user's home with nothing that reads it. Merge the branch
  carrying roles/claude-code's code-push tasks first, then re-run. See PET-507."
  done

  check_pem "$CODE_APP_PEM" "kv/services/claude-code-push"
  printf 'code-push: app %s, installation %s, pem %s bytes\n' \
    "$CODE_APP_ID" "$CODE_INSTALL_ID" "${#CODE_APP_PEM}"
fi

step "Resolving the read-only Proxmox token (PET-510)"
# OPTIONAL, for the reason the vault block above gives: 247 declares claude_pve_audit_enable
# permanently in host_vars. Four fields or none; some of them is a failed mint, not a state.
#
# ⚠ THE SESSION USER CAN READ THIS TOKEN. What bounds it is Proxmox: PVEAuditor on / for the
# user and for the token, with privilege separation, so it reads the cluster and changes
# nothing. ansible/playbooks/mint-claude-247-pve.yml writes this entry, once, from the Mac.

PVE_PRESENT=0
PVE_FOUND=0
for v in "$PVE_TOKEN_ID" "$PVE_TOKEN_SECRET" "$PVE_ENDPOINT" "$PVE_CA_PEM"; do
  [ -n "$v" ] && PVE_FOUND=$((PVE_FOUND + 1))
done

if [ "$PVE_FOUND" -eq 4 ]; then
  PVE_PRESENT=1
elif [ "$PVE_FOUND" -gt 0 ]; then
  die "kv/services/claude-247-pve is half-written: $PVE_FOUND of token_id, secret, endpoint, ca_pem are set.

  The mint playbook writes all four in one request, so this entry was written some other way.
  Remove the token on pve02 with 'pveum user token remove claude-247@pve audit', then run
  ansible/playbooks/mint-claude-247-pve.yml again."
else
  warn "kv/services/claude-247-pve is empty, so the Proxmox token is NOT being landed.

  Everything else in this run converges. To fix it, run
  ansible/playbooks/mint-claude-247-pve.yml from the Mac, and then this script again."
fi

if [ "$PVE_PRESENT" -eq 1 ]; then
  # The role grants PVEAuditor to this one token. Any other id in the entry is a token this
  # script cannot vouch for, and it might hold more than PVEAuditor.
  [ "$PVE_TOKEN_ID" = "claude-247@pve!audit" ] \
    || die "kv/services/claude-247-pve names the token '$PVE_TOKEN_ID', not claude-247@pve!audit.

  Only claude-247@pve!audit is bounded to PVEAuditor. Re-mint with
  ansible/playbooks/mint-claude-247-pve.yml."

  case "$PVE_ENDPOINT" in
    https://*) ;;
    *) die "endpoint in kv/services/claude-247-pve is '$PVE_ENDPOINT', not an https URL." ;;
  esac

  printf '%s' "$PVE_CA_PEM" | grep -q -- "-----BEGIN CERTIFICATE-----" \
    || die "ca_pem in kv/services/claude-247-pve does not look like a PEM certificate."
  printf '%s\n' "$PVE_CA_PEM" | openssl x509 -noout 2>/dev/null \
    || die "ca_pem in kv/services/claude-247-pve does not parse as an X.509 certificate. Re-mint it."

  for f in ansible/roles/claude-code/tasks/pve.yml \
           ansible/roles/claude-code/templates/claude-pve-get.j2 \
           ansible/roles/claude-code/templates/claude-pve-token.env.j2; do
    [ -f "$REPO_ROOT/$f" ] || die "$f is missing from this checkout.

  This tree has the Proxmox TOKEN but not the consumer. Landing it now would put a credential
  in the session user's home with nothing that reads it. Merge the branch carrying
  roles/claude-code's pve tasks first, then re-run. See PET-510."
  done

  printf 'pve: token %s, endpoint %s, secret %s bytes\n' \
    "$PVE_TOKEN_ID" "$PVE_ENDPOINT" "${#PVE_TOKEN_SECRET}"
fi

step "Resolving the Plane project id for '$PLANE_IDENTIFIER'"
# Looked up rather than pinned. A project UUID would have to be re-pinned every time the
# project is recreated, which plane-bootstrap.sh already learned once. The PAT goes to curl
# through stdin so it never reaches argv.
PROJECTS="$(printf 'X-API-Key: %s\n' "$PLANE_KEY" | curl -sS --max-time 20 -H @- \
  "${PLANE_BASE_URL%/}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/" 2>/dev/null)" \
  || die "Plane unreachable at $PLANE_BASE_URL — is the tailnet up?"

PROJECT_ID="$(printf '%s' "$PROJECTS" | PLANE_IDENTIFIER="$PLANE_IDENTIFIER" python3 -c '
import json, os, sys
want = os.environ["PLANE_IDENTIFIER"].upper()
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = d if isinstance(d, list) else (d.get("results") or [])
for p in rows:
    if str(p.get("identifier", "")).upper() == want:
        print(p["id"])
        break
')"
[ -n "$PROJECT_ID" ] || die "no project with identifier '$PLANE_IDENTIFIER' in workspace '$PLANE_WORKSPACE'."
printf 'project %s\n' "$PROJECT_ID"

step "Writing the extra-vars file"
# umask BEFORE the file exists, so the extra-vars never sit world-readable.
umask 077

# JSON, not YAML, and built by python rather than printf: a PEM is multi-line and full of
# characters that are a valid private key and an invalid bare YAML scalar.
#
# Every value travels in the ENVIRONMENT, never in argv — `ps` on a shared machine reads
# argv, and four of these are App private keys.
#
# The mirror's three keys are OMITTED, not blanked, when its Vault path is empty, and the
# vault's and the code-push App's three the same way. The role decides whether this run carries each identity by
# testing them for length, and an empty string and an undefined variable read the same there
# — but omitting them keeps a `-e` on the command line able to supply them, which a blank
# would silently override.
OUT="$OUT" \
APP_ID="$APP_ID" INSTALL_ID="$INSTALL_ID" APP_PEM="$APP_PEM" \
MIRROR_PRESENT="$MIRROR_PRESENT" MIRROR_APP_ID="$MIRROR_APP_ID" \
MIRROR_INSTALL_ID="$MIRROR_INSTALL_ID" MIRROR_APP_PEM="$MIRROR_APP_PEM" \
VAULT_PRESENT="$VAULT_PRESENT" VAULT_APP_ID="$VAULT_APP_ID" \
VAULT_INSTALL_ID="$VAULT_INSTALL_ID" VAULT_APP_PEM="$VAULT_APP_PEM" \
CODE_PRESENT="$CODE_PRESENT" CODE_APP_ID="$CODE_APP_ID" \
CODE_INSTALL_ID="$CODE_INSTALL_ID" CODE_APP_PEM="$CODE_APP_PEM" \
PVE_PRESENT="$PVE_PRESENT" PVE_TOKEN_ID="$PVE_TOKEN_ID" \
PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET" PVE_ENDPOINT="$PVE_ENDPOINT" PVE_CA_PEM="$PVE_CA_PEM" \
PLANE_KEY="$PLANE_KEY" PLANE_BASE_URL="$PLANE_BASE_URL" \
PLANE_WORKSPACE="$PLANE_WORKSPACE" PROJECT_ID="$PROJECT_ID" \
python3 -c '
import json, os
v = {
    "claude_loop_github_app_id": os.environ["APP_ID"],
    "claude_loop_github_installation_id": os.environ["INSTALL_ID"],
    "claude_loop_github_app_pem": os.environ["APP_PEM"],
    "claude_loop_plane_api_key": os.environ["PLANE_KEY"],
    "claude_loop_plane_base_url": os.environ["PLANE_BASE_URL"],
    "claude_loop_plane_workspace": os.environ["PLANE_WORKSPACE"],
    "claude_loop_plane_project_id": os.environ["PROJECT_ID"],
}
if os.environ["MIRROR_PRESENT"] == "1":
    v.update({
        "claude_workspace_mirror_app_id": os.environ["MIRROR_APP_ID"],
        "claude_workspace_mirror_installation_id": os.environ["MIRROR_INSTALL_ID"],
        "claude_workspace_mirror_app_pem": os.environ["MIRROR_APP_PEM"],
    })
if os.environ["VAULT_PRESENT"] == "1":
    v.update({
        "claude_vault_app_id": os.environ["VAULT_APP_ID"],
        "claude_vault_installation_id": os.environ["VAULT_INSTALL_ID"],
        "claude_vault_app_pem": os.environ["VAULT_APP_PEM"],
    })
if os.environ["CODE_PRESENT"] == "1":
    v.update({
        "claude_code_push_app_id": os.environ["CODE_APP_ID"],
        "claude_code_push_installation_id": os.environ["CODE_INSTALL_ID"],
        "claude_code_push_app_pem": os.environ["CODE_APP_PEM"],
    })
if os.environ["PVE_PRESENT"] == "1":
    v.update({
        "claude_pve_token_id": os.environ["PVE_TOKEN_ID"],
        "claude_pve_token_secret": os.environ["PVE_TOKEN_SECRET"],
        "claude_pve_endpoint": os.environ["PVE_ENDPOINT"],
        "claude_pve_ca_pem": os.environ["PVE_CA_PEM"],
    })
json.dump(v, open(os.environ["OUT"], "w"))
' || die "could not write the extra-vars file."
