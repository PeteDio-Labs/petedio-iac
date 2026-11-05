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
# into a public log. The last line is the summary lab-action.sh requires: hosts in the recap out of
# the hosts the playbook targets, changed, skipped, failed and unreachable, read from PLAY RECAP.
# The target count comes from `ansible-playbook --list-hosts` in the same container, so a run
# that missed a host it should have reached, or had any failed or unreachable host, exits
# non-zero, and so does a playbook that targets no node. A check skips command and shell tasks,
# which is where most guest steps live, so a check's changed=0 is not a promise.
#
# PINS. The image starts from python:3.12-slim by digest and installs
# scripts/lab-ansible-requirements.txt with hashes. The `ansible` package there bundles the
# collections at fixed versions, so the build reads nothing from Galaxy. The one floating input is
# the Debian openssh-client package, which carries no Ansible code. So a check and its apply, at
# the same commit, run the same Ansible and collections.
#
# INPUT. The playbook name is checked against a fixed pattern and the allowlist before anything
# else, and reaches the container's shell only as a positional argument, never as shell source.
#
# Needs: HOME holding .ssh/config, lab_runner and lab_runner-cert.pub (lab-action.sh), docker, and
# the pinned known_hosts file.
set -euo pipefail

MODE="${1:-}"
NAME="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KNOWN_HOSTS="${LAB_KNOWN_HOSTS:-/etc/ssh/lab-node-known-hosts}"
LIMIT='proxmox:pve_new:pve_gpu'

case "$MODE" in
  check) FLAGS=--check ;;
  apply) FLAGS= ;;
  *) echo "REFUSED: mode '$MODE' is not check or apply." >&2; exit 2 ;;
esac
# Refuse a malformed or unlisted name here, with no PyYAML needed, before it reaches Docker.
if ! [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*\.yml$ ]] \
   || ! sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REPO_ROOT/scripts/lab-playbooks.txt" | grep -qxF "$NAME"; then
  echo "REFUSED: '$NAME' is not a playbook name in scripts/lab-playbooks.txt." >&2
  exit 2
fi
# The full guard needs PyYAML. The runner may not have it, so the image runs the guard again below.
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
docker build -q -t "$TAG" -f - "$REPO_ROOT/scripts" > /dev/null <<'DOCKERFILE' || { echo "ABORT: could not build the Ansible image." >&2; exit 1; }
FROM python:3.12-slim@sha256:4840d514c583a4d3d8cad3940e68dee6f0f6f3635c12fcd0a3d74c21a5b93a54
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY lab-ansible-requirements.txt /tmp/requirements.txt
RUN pip install -q --no-cache-dir --require-hashes --no-deps -r /tmp/requirements.txt && pip check
DOCKERFILE

# Stage 2: run the play from that image on the host network, so its connections leave from the
# runner's own address, which the certificate's source-address names. It keeps one capability,
# DAC_OVERRIDE, because root in the container must read the runner user's 0600 key, and gains no
# privilege. ANSIBLE_SSH_ARGS replaces ansible.cfg's ssh_args, so the generated config, with
# strict host-key checking, governs every connection. The guard runs again here, at the same
# commit, before Ansible starts. Then `--list-hosts` prints the hosts the play targets, between
# two markers, for the count below. The name arrives as $1, and the key path and flags as $2
# and $3, so none of them is parsed as shell source.
# shellcheck disable=SC2016 # the single quotes keep $1, $2 and $3 for the container's shell
INNER='python3 /repo/scripts/lab-playbook-guard.py "$1" || exit 2
echo "--- lab-playbook targets ---"
ansible-playbook -i inventory/ "playbooks/$1" --limit "$LIMIT" --list-hosts || exit 2
echo "--- lab-playbook targets end ---"
exec ansible-playbook -i inventory/ "playbooks/$1" --limit "$LIMIT" \
  -e ansible_user=root -e "ansible_ssh_private_key_file=$2" ${3:+"$3"}'
set +e
docker run --rm --network host --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges \
  -v "$REPO_ROOT:/repo:ro" \
  -v "$HOME/.ssh:$HOME/.ssh:ro" \
  -v "$KNOWN_HOSTS:$KNOWN_HOSTS:ro" \
  -w /repo/ansible \
  -e LIMIT="$LIMIT" \
  -e ANSIBLE_SSH_ARGS="-F $HOME/.ssh/config -o ControlMaster=auto -o ControlPersist=60s" \
  -e ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore \
  -e ANSIBLE_NOCOLOR=1 \
  -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
  "$TAG" sh -c "$INNER" sh "$NAME" "$HOME/.ssh/lab_runner" "$FLAGS" \
  2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
set -e

# The hosts --list-hosts printed: the indented single words under each play's "hosts (N):".
EXPECTED=$(awk '
  /^--- lab-playbook targets ---$/ {t=1; next}
  /^--- lab-playbook targets end ---$/ {t=0}
  t && /hosts \([0-9]+\):/ {h=1; next}
  t && h && /^ +[^ :]+$/ {seen[$1]=1; next}
  {h=0}
  END {n=0; for (k in seen) n++; print n}' "$OUT")

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
echo "playbook $MODE $NAME: $HOSTS of $EXPECTED hosts, changed=$CHANGED, skipped=$SKIPPED, failed=$FAILED, unreachable=$UNREACH (ansible exit $RC)"
[ "$EXPECTED" -gt 0 ] && [ "$HOSTS" -eq "$EXPECTED" ] && [ "$FAILED" -eq 0 ] && [ "$UNREACH" -eq 0 ] && [ "$RC" -eq 0 ]
