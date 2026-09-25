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
# ⚠ FOUR APPS, AND THEY MUST STAY FOUR. scripts/claude-247-extra-vars.sh refuses all six
# mix-ups by App id, and says why each one matters. This script reads the fields and hands
# them to it.
#
# Operator run, from YOUR machine. This is the wrapper that keeps 247 free of a Vault
# credential: the AppRole login happens here, the fields are resolved here, and the host
# receives only the secrets it needs, as root-owned 0400 files. There is no role_id or
# secret_id on 247, and there is no Vault Agent — that was the retired fleet's shape and it
# put a renewable Vault token on a box whose sessions run in bypassPermissions.
#
# THE PRIMARY PATH IS THE WORKFLOW, AND THIS SCRIPT IS THE FALLBACK (PET-515).
# .github/workflows/ansible-claude-247.yml runs the same checks and the same play from the
# homelab runner, dispatched by hand:
#
#   gh workflow run ansible-claude-247.yml --ref main
#
# It reads these fields through the claude-247-deploy JWT role and policy in
# environments/homelab/vault-config, which name each path exactly. This script reads them
# through the `ansible` policy, which grants read on kv/data/services/*. Both hand the fields
# to scripts/claude-247-extra-vars.sh, so both refuse the same things with the same words.
#
#   ./scripts/deploy-claude-247.sh                            # land the identities, timer off
#   ./scripts/deploy-claude-247.sh -e claude_loop_enable=true # ... and start the loop timer
#
# ⚠ TURNING THE LOOP TIMER ON IS A SEPARATE DECISION FROM LANDING THE CREDENTIAL, which is
# why it is a flag you type and not the default. Run the tick by hand once first —
# docs/runbooks/claude-loop.md, "Before you enable it". The mirror's timer is not gated that
# way: it fetches a read-only repository into /var/lib and changes nothing off the host.
#
# The workflow has no loop input, so turning the timer on still goes through this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault ansible-playbook; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

applogin() {
  local rid sid
  rid="$(cat "$SECRETS/$1.role_id")"
  sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null \
    || die "AppRole login failed for '$1'."
}

step "Reading 247's identities from Vault (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
kvget() { VAULT_TOKEN="$AN_TOKEN" vault kv get -field="$2" "$1" 2>/dev/null || true; }

# EXPORTED, not passed: scripts/claude-247-extra-vars.sh takes every input from its
# environment, because `ps` on a shared machine reads argv and four of these are App
# private keys. A field that is absent reads as empty, and the checks there decide what an
# empty field means.
APP_ID="$(kvget kv/services/claude-loop app_id)"
INSTALL_ID="$(kvget kv/services/claude-loop installation_id)"
APP_PEM="$(kvget kv/services/claude-loop app_pem)"
PLANE_KEY="$(kvget kv/services/plane api_key)"
MIRROR_APP_ID="$(kvget kv/services/claude-workspace-mirror app_id)"
MIRROR_INSTALL_ID="$(kvget kv/services/claude-workspace-mirror installation_id)"
MIRROR_APP_PEM="$(kvget kv/services/claude-workspace-mirror app_pem)"
VAULT_APP_ID="$(kvget kv/services/claude-vault-push app_id)"
VAULT_INSTALL_ID="$(kvget kv/services/claude-vault-push installation_id)"
VAULT_APP_PEM="$(kvget kv/services/claude-vault-push app_pem)"
CODE_APP_ID="$(kvget kv/services/claude-code-push app_id)"
CODE_INSTALL_ID="$(kvget kv/services/claude-code-push installation_id)"
CODE_APP_PEM="$(kvget kv/services/claude-code-push app_pem)"
PVE_TOKEN_ID="$(kvget kv/services/claude-247-pve token_id)"
PVE_TOKEN_SECRET="$(kvget kv/services/claude-247-pve secret)"
PVE_ENDPOINT="$(kvget kv/services/claude-247-pve endpoint)"
PVE_CA_PEM="$(kvget kv/services/claude-247-pve ca_pem)"
export APP_ID INSTALL_ID APP_PEM PLANE_KEY \
  MIRROR_APP_ID MIRROR_INSTALL_ID MIRROR_APP_PEM \
  VAULT_APP_ID VAULT_INSTALL_ID VAULT_APP_PEM \
  CODE_APP_ID CODE_INSTALL_ID CODE_APP_PEM \
  PVE_TOKEN_ID PVE_TOKEN_SECRET PVE_ENDPOINT PVE_CA_PEM

# umask BEFORE the temp file exists, so the extra-vars never sit world-readable. mktemp -d
# gives a 0700 parent, but the file inside it inherits the process umask.
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The checks and the JSON writer. It prints its own ABORT and exits 1 on any refusal.
"$SCRIPT_DIR/claude-247-extra-vars.sh" "$TMP/extra.json"
unset APP_PEM PLANE_KEY MIRROR_APP_PEM VAULT_APP_PEM CODE_APP_PEM PVE_TOKEN_SECRET PVE_CA_PEM

step "Running configure-claude-code.yml (247's identities)"
cd "$ANSIBLE_DIR"
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

  Until then the play does not start that directory's unit, and fails naming it (PET-499).
  A server started in an untrusted directory exits at once, and five starts in 5 minutes land
  its unit in `failed`. That is the opposite of the Remote Control consent, which waits at its
  prompt while systemd reports the unit active (PET-431). After the dialog, re-run this
  script, or as root run:

    systemctl reset-failed claude-remote-<name> && systemctl start claude-remote-<name>

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
    the token   ansible/roles/claude-code/README.md, "The read-only Proxmox token (PET-510)"
TXT
