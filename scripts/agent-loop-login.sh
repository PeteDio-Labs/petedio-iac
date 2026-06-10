#!/usr/bin/env bash
# agent-loop-login.sh — interactive auth bootstrap for the agent-loop host (LXC 242, PET-125).
#
# Run this FROM THE MAC, after the host exists and is provisioned:
#   1. PET-125 PR merged → runner applies TF → LXC 242 (192.168.50.242) created
#      (pre-req: Ubuntu template on pve01 — see environments/homelab/agent-loop.tf header)
#   2. ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/configure-agent-loop.yml
#      (installs Node LTS + Claude Code + gh, and the `agent` loop user)
#
# Then this script SSHes in (root, via the TF-installed key), drops to the loop
# user `agent`, and runs the two interactive logins the loop needs:
#   * gh auth login   — GitHub device-code flow (push branches / open PRs)
#   * claude          — Claude Code OAuth. On this headless box it prints a URL;
#                       press `c` to copy, open it on the Mac, approve, paste the
#                       code back. Creds persist, so the loop's `claude -p` reuses them.
#
# Modes:
#   ./scripts/agent-loop-login.sh           # (login) run the interactive gh + claude logins
#   ./scripts/agent-loop-login.sh token     # print the unattended long-lived-token recipe
#
# Overridable via env: AGENT_LOOP_HOST, AGENT_LOOP_SSH_USER, AGENT_LOOP_SSH_KEY, AGENT_LOOP_USER
set -euo pipefail

HOST="${AGENT_LOOP_HOST:-192.168.50.242}"
SSH_USER="${AGENT_LOOP_SSH_USER:-root}"
SSH_KEY="${AGENT_LOOP_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
LOOP_USER="${AGENT_LOOP_USER:-agent}"

ssh_base=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$SSH_USER@$HOST")

case "${1:-login}" in
  login)
    [ -f "$SSH_KEY" ] || { echo "✗ SSH key not found: $SSH_KEY" >&2; exit 1; }
    echo "→ ${SSH_USER}@${HOST} (key: ${SSH_KEY}) → su - ${LOOP_USER}"
    echo "  Two interactive logins follow: gh (device code), then claude (URL on your Mac)."
    echo
    # Deliver the remote steps as a file first (avoids nested-quote hell over SSH),
    # then run it as `agent` over a TTY so the interactive prompts work.
    "${ssh_base[@]}" "cat > /tmp/agent-login.sh && chmod 0755 /tmp/agent-login.sh && chown ${LOOP_USER}: /tmp/agent-login.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
echo "== gh: $(gh --version | head -1) =="
if gh auth status >/dev/null 2>&1; then
  echo "gh: already authenticated"
else
  gh auth login
fi
echo
echo "== claude: $(claude --version) =="
echo "If not logged in, claude prints a URL — open it on your Mac, approve, paste the code."
echo "Type /exit (or Ctrl-C) once you're logged in."
claude
REMOTE
    exec "${ssh_base[@]}" -t "su - ${LOOP_USER} -c /tmp/agent-login.sh"
    ;;

  token)
    # Unattended path for run-loop.sh (`claude -p` in cron/systemd): a long-lived
    # OAuth token beats a persisted interactive session.
    cat <<EOF
Unattended Claude Code auth (recommended for the loop):

  1. On THIS Mac (browser available), generate a ~1-year OAuth token:
         claude setup-token        # prints a token; it is NOT saved anywhere

  2. Store it for the loop user on the host (mode 0600):
         ${ssh_base[*]} \\
           "su - ${LOOP_USER} -c 'umask 077 && mkdir -p ~/.config && cat > ~/.config/claude-oauth-token'"
     (paste the token, then Ctrl-D)

  3. run-loop.sh exports it before invoking claude:
         export CLAUDE_CODE_OAUTH_TOKEN="\$(cat ~/.config/claude-oauth-token)"

  Or store the token in Vault kv/services/agent-loop alongside the gh token and
  pull both in run-loop.sh — keeps every secret for this host in one place.

  gh stays the same: run \`$0\` (login mode) once, or set GH_TOKEN from Vault.
EOF
    ;;

  *)
    echo "usage: $0 [login|token]" >&2
    exit 2
    ;;
esac
