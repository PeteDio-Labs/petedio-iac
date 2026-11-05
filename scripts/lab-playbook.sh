#!/usr/bin/env bash
# lab-playbook — run one allowlisted playbook against the Proxmox nodes (PET-861, phase 2).
#
#   scripts/lab-playbook.sh check <playbook.yml>   # ansible-playbook --check
#   scripts/lab-playbook.sh apply <playbook.yml>   # a real run
#
# scripts/lab-action.sh calls this after it has signed the lab-runner certificate and written the
# ssh config, so it runs only inside a lab-action.yml job. A check runs with no approval. An apply
# runs only in the `lab-write` job, which waits for Pedro's approval in GitHub and runs after a
# clean check at the same commit.
#
# SCOPE. The certificate opens root on pve01, pve02 and pve03 only, so every run is limited to the
# node groups. scripts/lab-playbook-guard.py refuses a playbook that is not in
# scripts/lab-playbooks.txt, or whose tree has an unmarked `check_mode: false`, because such a task
# runs for real inside a check.
#
# OUTPUT. No --diff, because diffs print file contents into a public log. The last line is the
# summary lab-action.sh requires: hosts, changed, failed and unreachable, read from PLAY RECAP. A
# run that matched zero hosts, or any failed or unreachable host, exits non-zero.
#
# Needs: HOME holding .ssh/config, lab_runner and lab_runner-cert.pub (lab-action.sh), docker, and
# the pinned known_hosts file.
set -euo pipefail

MODE="${1:-}"
NAME="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KNOWN_HOSTS="${LAB_KNOWN_HOSTS:-/etc/ssh/lab-node-known-hosts}"
LIMIT='proxmox:pve_new:pve_gpu'
IMAGE='python:3.12-slim'

case "$MODE" in
  check) FLAGS=(--check) ;;
  apply) FLAGS=() ;;
  *) echo "REFUSED: mode '$MODE' is not check or apply." >&2; exit 2 ;;
esac
python3 "$REPO_ROOT/scripts/lab-playbook-guard.py" "$NAME" || exit 2

for f in "$HOME/.ssh/config" "$HOME/.ssh/lab_runner" "$HOME/.ssh/lab_runner-cert.pub" "$KNOWN_HOSTS"; do
  [ -r "$f" ] || { echo "ABORT: $f is missing; run this through scripts/lab-action.sh." >&2; exit 1; }
done

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# Ansible runs in a throwaway container on the host network, so its connections leave from the
# runner's own address, which the certificate's source-address names. ANSIBLE_SSH_ARGS replaces
# ansible.cfg's ssh_args, so the generated config, with strict host-key checking, governs every
# connection.
set +e
docker run --rm --network host \
  -v "$REPO_ROOT/ansible:/ansible:ro" \
  -v "$REPO_ROOT/environments/homelab/vault-ca.crt:/environments/homelab/vault-ca.crt:ro" \
  -v "$HOME/.ssh:$HOME/.ssh:ro" \
  -v "$KNOWN_HOSTS:$KNOWN_HOSTS:ro" \
  -w /ansible \
  -e ANSIBLE_SSH_ARGS="-F $HOME/.ssh/config -o ControlMaster=auto -o ControlPersist=60s" \
  -e ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore \
  -e ANSIBLE_NOCOLOR=1 \
  -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
  "$IMAGE" sh -c \
  "apt-get update -q >/dev/null && apt-get install -y -q openssh-client >/dev/null && \
   pip install -q 'ansible-core==2.20.4' && \
   ansible-galaxy collection install -r requirements.yml >/dev/null && \
   ansible-playbook -i inventory/ 'playbooks/$NAME' --limit '$LIMIT' \
     -e ansible_user=root -e ansible_ssh_private_key_file=$HOME/.ssh/lab_runner ${FLAGS[*]}" \
  2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
set -e

# PLAY RECAP lines: "<host> : ok=N changed=N unreachable=N failed=N skipped=N ...".
read -r HOSTS CHANGED UNREACH FAILED < <(awk '
  /^PLAY RECAP/ {r=1; next}
  r && / : ok=/ {
    h++
    for (i = 1; i <= NF; i++) {
      split($i, kv, "=")
      if (kv[1] == "changed") c += kv[2]
      if (kv[1] == "unreachable") u += kv[2]
      if (kv[1] == "failed") f += kv[2]
    }
  }
  END {print h+0, c+0, u+0, f+0}' "$OUT")

echo "playbook $MODE $NAME: $HOSTS hosts, changed=$CHANGED, failed=$FAILED, unreachable=$UNREACH (ansible exit $RC)"
[ "$HOSTS" -gt 0 ] && [ "$FAILED" -eq 0 ] && [ "$UNREACH" -eq 0 ] && [ "$RC" -eq 0 ]
