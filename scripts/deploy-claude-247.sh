#!/usr/bin/env bash
# deploy-claude-247.sh — resolve LXC 247's identities from Vault and run
# configure-claude-code.yml against it (PET-399, PET-493).
#
# ⚠ THIS WAS deploy-claude-loop.sh UNTIL PET-493. It carried one identity then. It now
# carries three, and no one of their names fits the others, so the script is named for the
# HOST:
#
#   kv/services/claude-loop              -> app_id, installation_id, app_pem   (REQUIRED)
#     The work loop's bot identity. contents:write and pull_requests:write, because it
#     opens draft PRs.
#   kv/services/plane                    -> api_key                            (REQUIRED)
#     The PAT CI already uses.
#   kv/services/claude-workspace-mirror  -> app_id, installation_id, app_pem   (optional)
#     The petedio-workspace delivery identity. Contents and Metadata READ-ONLY, installed on
#     that one repository. Absent, this script warns and the play delivers the mirror from
#     whatever is already on 247.
#   kv/services/claude-vault-push        -> app_id, installation_id, app_pem   (optional)
#     The petedio-vault identity (PET-498). contents:WRITE and metadata:read, installed on
#     that one repository, because a session on 247 pushes vault notes to `main`. Absent,
#     this script warns and the play leaves the vault clone as it found it.
#   kv/services/claude-code-push         -> app_id, installation_id, app_pem   (optional)
#     The code-push identity (PET-507). contents:write, pull_requests:write and metadata:read
#     on petedio-iac, petedio-media-iac and petedio-workspace, because a session on 247
#     pushes branches and opens pull requests there. No `workflows` permission. Absent, this
#     script warns and the play leaves the three clones' git config as it found it.
#
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
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
#
# Operator run, from YOUR machine. This is the wrapper that keeps 247 free of a Vault
# credential: the AppRole login happens here, the fields are resolved here, and the host
# receives only the secrets it needs, as root-owned 0400 files. There is no role_id or
# secret_id on 247, and there is no Vault Agent — that was the retired fleet's shape and it
# put a renewable Vault token on a box whose sessions run in bypassPermissions.
#
# The `ansible` policy already grants read on kv/data/services/* — see
# environments/homelab/vault-config/policies.tf. NO vault-config change is needed for this,
# and a plan that proposes one is repointing something else.
#
#   ./scripts/deploy-claude-247.sh                            # land the identities, timer off
#   ./scripts/deploy-claude-247.sh -e claude_loop_enable=true # ... and start the loop timer
#
# ⚠ TURNING THE LOOP TIMER ON IS A SEPARATE DECISION FROM LANDING THE CREDENTIAL, which is
# why it is a flag you type and not the default. Run the tick by hand once first —
# docs/runbooks/claude-loop.md, "Before you enable it". The mirror's timer is not gated that
# way: it fetches a read-only repository into /var/lib and changes nothing off the host.
#
# Manual-validation-first (standing convention, PET-266): this script IS the manual-deploy
# proof step. Nothing in .github/workflows watches configure-claude-code.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

PLANE_BASE_URL="${PLANE_BASE_URL:-http://192.168.50.235:8080}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-petedio}"
PLANE_IDENTIFIER="${PLANE_IDENTIFIER:-PET}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault ansible-playbook python3 curl; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

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

applogin() {
  local rid sid
  rid="$(cat "$SECRETS/$1.role_id")"
  sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null \
    || die "AppRole login failed for '$1'."
}

# A PEM that survived a copy-paste as one line signs nothing, and openssl's complaint about
# it points at the signature, not the field. Check the shape here, where the fix is obvious.
check_pem() {
  local pem="$1" where="$2"
  printf '%s' "$pem" | grep -q -- "-----BEGIN .*PRIVATE KEY-----" \
    || die "app_pem in $where does not look like a PEM private key. Re-seed it with the .pem file GitHub gave you, newlines intact."
  [ "$(printf '%s' "$pem" | wc -l)" -ge 3 ] \
    || die "app_pem in $where is a single line — its newlines were lost on the way into Vault. Re-seed it."
}

step "Resolving the loop identity (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
kvget() { VAULT_TOKEN="$AN_TOKEN" vault kv get -field="$2" "$1" 2>/dev/null || true; }

APP_ID="$(kvget kv/services/claude-loop app_id)"
INSTALL_ID="$(kvget kv/services/claude-loop installation_id)"
APP_PEM="$(kvget kv/services/claude-loop app_pem)"
PLANE_KEY="$(kvget kv/services/plane api_key)"

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
MIRROR_APP_ID="$(kvget kv/services/claude-workspace-mirror app_id)"
MIRROR_INSTALL_ID="$(kvget kv/services/claude-workspace-mirror installation_id)"
MIRROR_APP_PEM="$(kvget kv/services/claude-workspace-mirror app_pem)"

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
VAULT_APP_ID="$(kvget kv/services/claude-vault-push app_id)"
VAULT_INSTALL_ID="$(kvget kv/services/claude-vault-push installation_id)"
VAULT_APP_PEM="$(kvget kv/services/claude-vault-push app_pem)"

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
CODE_APP_ID="$(kvget kv/services/claude-code-push app_id)"
CODE_INSTALL_ID="$(kvget kv/services/claude-code-push installation_id)"
CODE_APP_PEM="$(kvget kv/services/claude-code-push app_pem)"

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

step "Running configure-claude-code.yml (247's identities)"
cd "$ANSIBLE_DIR"
# umask BEFORE the temp file exists, so the extra-vars never sit world-readable. mktemp -d
# gives a 0700 parent, but the file inside it inherits the process umask.
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# JSON, not YAML, and built by python rather than printf: a PEM is multi-line and full of
# characters that are a valid private key and an invalid bare YAML scalar.
#
# Every value travels in the ENVIRONMENT, never in argv — `ps` on a shared machine reads
# argv, and two of these are App private keys.
#
# The mirror's three keys are OMITTED, not blanked, when its Vault path is empty, and the
# vault's and the code-push App's three the same way. The role decides whether this run carries each identity by
# testing them for length, and an empty string and an undefined variable read the same there
# — but omitting them keeps a `-e` on the command line able to supply them, which a blank
# would silently override.
OUT="$TMP/extra.json" \
APP_ID="$APP_ID" INSTALL_ID="$INSTALL_ID" APP_PEM="$APP_PEM" \
MIRROR_PRESENT="$MIRROR_PRESENT" MIRROR_APP_ID="$MIRROR_APP_ID" \
MIRROR_INSTALL_ID="$MIRROR_INSTALL_ID" MIRROR_APP_PEM="$MIRROR_APP_PEM" \
VAULT_PRESENT="$VAULT_PRESENT" VAULT_APP_ID="$VAULT_APP_ID" \
VAULT_INSTALL_ID="$VAULT_INSTALL_ID" VAULT_APP_PEM="$VAULT_APP_PEM" \
CODE_PRESENT="$CODE_PRESENT" CODE_APP_ID="$CODE_APP_ID" \
CODE_INSTALL_ID="$CODE_INSTALL_ID" CODE_APP_PEM="$CODE_APP_PEM" \
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
json.dump(v, open(os.environ["OUT"], "w"))
' || die "could not write the extra-vars file."
unset APP_PEM PLANE_KEY MIRROR_APP_PEM VAULT_APP_PEM CODE_APP_PEM

ansible-playbook playbooks/configure-claude-code.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  Re-run this script to confirm idempotence — a converged host must report changed=0.

  THE LOOP TIMER is OFF unless you passed -e claude_loop_enable=true. Before you turn it on,
  run one tick by hand and read what it did. The commands are in
  docs/runbooks/claude-loop.md, under "Before you enable it". They run as root on
  claude-247, which has no sudo and no operator account. This text does not repeat them,
  because a copy here went stale once (PET-485).

  Then, once a draft PR from the bot looks right:

    ./scripts/deploy-claude-247.sh -e claude_loop_enable=true
    ./scripts/lab-verify.sh | grep -i loop

  THE WORKSPACE MIRROR needs one step no play can take, because the dialog is interactive:

    ssh claude@192.168.50.247
    cd ~/work/petedio/workspace && claude      # accept the trust dialog, then /exit

  Until then a session started in that directory waits at the prompt while systemd reports
  its unit active — the same failure PET-431 documents for the Remote Control consent.

  THE VAULT CLONE needs that same interactive step, in its own directory:

    ssh claude@192.168.50.247
    cd ~/work/petedio/vault && claude          # accept the trust dialog, then /exit

  ⚠ AND ITS SESSION CAN PUSH TO petedio-vault `main`. That is what PET-498 asked for, and it
  is the only outbound write credential on this host a session can read. The App bounds it to
  that one repository, with contents:write and metadata:read and no pull-request rights.
  Rotating or revoking it is a GitHub-side act; this script cannot detect that it happened.

  Full sequences, including how to pause and how to rotate each App key:
    the loop    docs/runbooks/claude-loop.md
    the mirror  ansible/roles/claude-code/README.md, "The private workspace repo"
    the vault   ansible/roles/claude-code/README.md, "The vault, and the one writable key"
TXT
