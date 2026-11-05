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
# scripts/lab-playbooks.txt, or whose tree has an unmarked `check_mode` that is not true, because
# such a task runs for real inside a check.
#
# OUTPUT. No --diff, and the guard refuses a task-level `diff`, because diffs print file contents
# into a public log. The last line is the summary lab-action.sh requires: hosts out of the three
# expected, changed, skipped, failed and unreachable, read from PLAY RECAP. A run that missed a
# node, or had any failed or unreachable host, exits non-zero. A check skips command and shell
# tasks, which is where most guest steps live, so a check's changed=0 is not a promise.
#
# Needs: HOME holding .ssh/config, lab_runner and lab_runner-cert.pub (lab-action.sh), docker, and
# the pinned known_hosts file. The image builds from the floating python:3.12-slim tag and
# requirements.yml, some of whose collections float too, so a check and its apply can resolve
# different collection versions.
set -euo pipefail

MODE="${1:-}"
NAME="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KNOWN_HOSTS="${LAB_KNOWN_HOSTS:-/etc/ssh/lab-node-known-hosts}"
LIMIT='proxmox:pve_new:pve_gpu'
# The three nodes in the node groups. A recap with fewer hosts means the inventory dropped one.
EXPECTED_HOSTS=3

case "$MODE" in
  check) FLAGS=--check ;;
  apply) FLAGS= ;;
  *) echo "REFUSED: mode '$MODE' is not check or apply." >&2; exit 2 ;;
esac
# The guard needs PyYAML. The runner may not have it, so the image runs the guard again below.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 "$REPO_ROOT/scripts/lab-playbook-guard.py" "$NAME" || exit 2
fi

for f in "$HOME/.ssh/config" "$HOME/.ssh/lab_runner" "$HOME/.ssh/lab_runner-cert.pub" "$KNOWN_HOSTS"; do
  [ -r "$f" ] || { echo "ABORT: $f is missing; run this through scripts/lab-action.sh." >&2; exit 1; }
done

OUT="$(mktemp)"
TAG="lab-ansible:$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)-$$"
trap 'rm -f "$OUT"; docker image rm -f "$TAG" >/dev/null 2>&1 || true' EXIT

# Stage 1, with no certificate anywhere in reach: build an image holding the ssh client,
# ansible-core and the collections. Every install script from apt, pip and Galaxy runs here, so
# none of them can read the certificate.
docker build -q -t "$TAG" -f - "$REPO_ROOT/ansible" > /dev/null <<'DOCKERFILE' || { echo "ABORT: could not build the Ansible image." >&2; exit 1; }
FROM python:3.12-slim
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*
RUN pip install -q --no-cache-dir 'ansible-core==2.20.4'
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p /usr/share/ansible/collections
DOCKERFILE

# Stage 2: run the play from that image on the host network, so its connections leave from the
# runner's own address, which the certificate's source-address names. It keeps one capability,
# DAC_OVERRIDE, because root in the container must read the runner user's 0600 key, and gains no
# privilege. ANSIBLE_SSH_ARGS replaces ansible.cfg's ssh_args, so the generated config, with
# strict host-key checking, governs every connection. The guard runs again here, at the same
# commit, before Ansible starts.
set +e
docker run --rm --network host --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges \
  -v "$REPO_ROOT:/repo:ro" \
  -v "$HOME/.ssh:$HOME/.ssh:ro" \
  -v "$KNOWN_HOSTS:$KNOWN_HOSTS:ro" \
  -w /repo/ansible \
  -e ANSIBLE_SSH_ARGS="-F $HOME/.ssh/config -o ControlMaster=auto -o ControlPersist=60s" \
  -e ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore \
  -e ANSIBLE_NOCOLOR=1 \
  -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
  "$TAG" sh -c \
  "python3 /repo/scripts/lab-playbook-guard.py '$NAME' && \
   ansible-playbook -i inventory/ 'playbooks/$NAME' --limit '$LIMIT' \
     -e ansible_user=root -e ansible_ssh_private_key_file=$HOME/.ssh/lab_runner $FLAGS" \
  2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
set -e

# PLAY RECAP lines: "<host> : ok=N changed=N unreachable=N failed=N skipped=N ...".
read -r HOSTS CHANGED UNREACH FAILED SKIPPED < <(awk '
  /^PLAY RECAP/ {r=1; next}
  r && / : ok=/ {
    h++
    for (i = 1; i <= NF; i++) {
      split($i, kv, "=")
      if (kv[1] == "changed") c += kv[2]
      if (kv[1] == "unreachable") u += kv[2]
      if (kv[1] == "failed") f += kv[2]
      if (kv[1] == "skipped") s += kv[2]
    }
  }
  END {print h+0, c+0, u+0, f+0, s+0}' "$OUT")

# A check skips command and shell tasks, so a guest step can show as skipped, not changed. The
# summary names the skips, so changed=0 is never read as "nothing will happen".
echo "playbook $MODE $NAME: $HOSTS of $EXPECTED_HOSTS hosts, changed=$CHANGED, skipped=$SKIPPED, failed=$FAILED, unreachable=$UNREACH (ansible exit $RC)"
[ "$HOSTS" -eq "$EXPECTED_HOSTS" ] && [ "$FAILED" -eq 0 ] && [ "$UNREACH" -eq 0 ] && [ "$RC" -eq 0 ]
