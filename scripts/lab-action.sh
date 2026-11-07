#!/usr/bin/env bash
# lab-action — run one allowlisted lab action from the homelab runner (PET-861).
#
#   scripts/lab-action.sh lab_verify    # scripts/lab-verify.sh --quiet
#   scripts/lab-action.sh lab_updates   # scripts/lab-updates.sh
#   scripts/lab-action.sh playbook_check <playbook.yml>   # scripts/lab-playbook.sh check
#   scripts/lab-action.sh playbook_apply <playbook.yml>   # only in the lab-write job
#   scripts/lab-action.sh lab_probe <journal|mtrace|media_ask> "<key=value ...>"   # read-only, on 237
#
# .github/workflows/lab-action.yml calls this on a homelab runner when a thread dispatches it, so
# a read-back no longer needs a paste-in prompt on 247 or the Mac. Both actions are checks, so
# they run with no approval. A write action belongs to a later phase and waits on the `lab-write`
# environment, which only Pedro can approve.
#
# HOW IT REACHES THE NODES. It makes a fresh ed25519 key in a temporary HOME and asks Vault to
# sign it as lab-runner (vault-config/ssh.tf). The nodes map that principal to root
# (roles/ssh-ca, group_vars for the node groups). The certificate works only from runners 232
# and 233, because both carry the homelab label and either can take the job, and only for 30
# minutes. The key and certificate are deleted on exit. No standing key exists anywhere.
#
# WHAT IT PRINTS. The run log is public, because petedio-iac is. The scripts print status and
# counts, never values. This wrapper also masks any run of 32 or more letters, digits, `_` or
# `-`, which covers API keys and tokens and, as a cost, commit SHAs. It exits non-zero when the
# action fails, when Vault refuses, and when the script ends without its summary line, so a run
# that examined nothing never reads as green.
#
# SIDE EFFECTS. lab-verify.sh is not purely a read: to prove storage works, it creates and then
# deletes one temporary file each in /etc/pve, /mnt/downloads, the guests' media mounts and an
# arr release directory. Those probes stay. Under LAB_ACTION=1 it skips its one probe that pulls
# and runs a container image (hello-world on the runners).
#
# Needs: VAULT_ADDR, VAULT_CACERT and VAULT_TOKEN (the lab-action-read role), curl, python3,
# ssh-keygen, ssh, and the pinned node keys in /etc/ssh/lab-node-known-hosts.
set -euo pipefail

ACTION="${1:-}"
TARGET="${2:-}"
PROBE_ARGS="${3:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The allowlist. An action not named here is refused before anything is signed.
case "$ACTION" in
  lab_verify)  CMD=("$REPO_ROOT/scripts/lab-verify.sh" --quiet); SUMMARY='^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped' ;;
  lab_updates) CMD=("$REPO_ROOT/scripts/lab-updates.sh");        SUMMARY='^examined [0-9]+ hosts or guests' ;;
  # Phase 2: a playbook on the nodes. lab-playbook.sh runs the guard before Ansible starts. The
  # workflow runs playbook_apply only in the lab-write job, after a clean check at the same commit.
  playbook_check|playbook_apply)
    # The name must match a fixed pattern and appear in the allowlist before anything is signed.
    # This needs no PyYAML, so it holds on a runner without it.
    if ! [[ "$TARGET" =~ ^[a-z0-9][a-z0-9-]*\.yml$ ]] \
       || ! sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REPO_ROOT/scripts/lab-playbooks.txt" | grep -qxF "$TARGET"; then
      echo "REFUSED: '$TARGET' is not a playbook name in scripts/lab-playbooks.txt." >&2
      exit 2
    fi
    if python3 -c 'import yaml' 2>/dev/null; then
      python3 "$REPO_ROOT/scripts/lab-playbook-guard.py" "$TARGET" || exit 2
    fi
    CMD=("$REPO_ROOT/scripts/lab-playbook.sh" "${ACTION#playbook_}" "$TARGET")
    SUMMARY='^playbook (check|apply) [a-z0-9-]+\.yml: [0-9]+ of [0-9]+ hosts' ;;
  # A read-only probe inside LXC 237 (PET-878, PET-879). scripts/lab-probe.sh validates each value against a
  # strict pattern and reads lab-agent's own token inside 237; nothing is placed.
  lab_probe)
    [[ "$TARGET" =~ ^(journal|mtrace|media_ask|guests)$ ]] || { echo "REFUSED: '$TARGET' is not a probe (journal, mtrace, media_ask, guests)." >&2; exit 2; }
    CMD=("$REPO_ROOT/scripts/lab-probe.sh" "$TARGET" "$PROBE_ARGS")
    SUMMARY='^probe (journal|mtrace|media_ask|guests):' ;;
  *) echo "REFUSED: '$ACTION' is not an allowlisted action (lab_verify, lab_updates, lab_probe, playbook_check, playbook_apply)." >&2; exit 2 ;;
esac

for v in VAULT_ADDR VAULT_CACERT VAULT_TOKEN; do
  [ -n "${!v:-}" ] || { echo "ABORT: $v is not set; the job did not log in to Vault." >&2; exit 1; }
done

# The nodes' host keys, pinned by ansible/playbooks/configure-lab-runner-known-hosts.yml. Check
# before anything is signed, so a runner without them mints no certificate.
KNOWN_HOSTS="${LAB_KNOWN_HOSTS:-/etc/ssh/lab-node-known-hosts}"
for h in 192.168.50.10 192.168.50.11 192.168.50.12; do
  grep -qE "(^|,)$h ssh-ed25519 " "$KNOWN_HOSTS" 2>/dev/null || {
    echo "ABORT: no pinned host key for $h in $KNOWN_HOSTS; run configure-lab-runner-known-hosts.yml." >&2
    exit 1
  }
done

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME/.ssh"

# Sign a fresh key. A sealed Vault refuses here, and the run fails with Vault's own words.
ssh-keygen -q -t ed25519 -N '' -C "lab-action-$ACTION" -f "$HOME/.ssh/lab_runner"
python3 -c 'import json,sys; print(json.dumps({"public_key": open(sys.argv[1]).read().strip()}))' \
  "$HOME/.ssh/lab_runner.pub" > "$WORK/sign.json"
# The token goes in a 0600 header file, never on curl's command line, where another local user
# could read it from the process list.
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$WORK/vault.hdr"
if ! curl -sS --fail-with-body --cacert "$VAULT_CACERT" -m 15 \
    -H @"$WORK/vault.hdr" -X POST --data @"$WORK/sign.json" \
    "$VAULT_ADDR/v1/ssh-client-signer/sign/lab-runner" > "$WORK/signed.json"; then
  echo "ABORT: Vault refused to sign the lab-runner key: $(head -c 300 "$WORK/signed.json")" >&2
  exit 1
fi
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["signed_key"].strip())' \
  "$WORK/signed.json" > "$HOME/.ssh/lab_runner-cert.pub"
ssh-keygen -L -f "$HOME/.ssh/lab_runner-cert.pub" | grep -q '^ *lab-runner$' \
  || { echo "ABORT: the signed certificate does not name the lab-runner principal." >&2; exit 1; }
# The scripts need no Vault access. Revoke the token now, so it dies with the signing and not at
# the end of its TTL, and never hand it to them.
curl -sS --fail --cacert "$VAULT_CACERT" -m 10 -o /dev/null -H @"$WORK/vault.hdr" \
  -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" \
  || echo "WARN: could not revoke the Vault token; it expires at the end of its 15-minute TTL." >&2
unset VAULT_TOKEN
rm -f "$WORK/vault.hdr"
# lab-verify.sh skips, rather than fails, the checks this runner has no key for, and skips the
# probe that pulls and runs an image.
export LAB_ACTION=1

# The aliases lab-verify.sh and lab-updates.sh use, mapped to the nodes' addresses as root. pve01
# is reached by address in lab-verify.sh, so it gets a Host block by address. pi1 and the runners
# accept no lab-runner certificate, so lab-verify.sh skips their checks under LAB_ACTION=1.
#
# Host keys: only the pinned file counts, with StrictHostKeyChecking=yes, so a machine that answers
# in a node's place is refused before any output reaches the scripts. lab-verify.sh passes some
# node output to `eval`, so trusting a first contact would let an impostor run commands here.
cat > "$HOME/.ssh/config" <<EOF
Host pve02
  HostName 192.168.50.11
Host pve03
  HostName 192.168.50.10
Host pve02 pve03 192.168.50.10 192.168.50.11 192.168.50.12
  User root
  IdentityFile $HOME/.ssh/lab_runner
  CertificateFile $HOME/.ssh/lab_runner-cert.pub
  IdentitiesOnly yes
Host *
  StrictHostKeyChecking yes
  UserKnownHostsFile $KNOWN_HOSTS
  GlobalKnownHostsFile $KNOWN_HOSTS
EOF

# ssh reads ~/.ssh/config from the account's passwd home, not from $HOME, so the scripts' plain
# `ssh` calls would never see this config. A wrapper first on PATH passes it with -F.
mkdir -p "$WORK/bin"
REAL_SSH="$(command -v ssh)"
printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$REAL_SSH" "$HOME/.ssh/config" > "$WORK/bin/ssh"
chmod 700 "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

echo "lab-action: $ACTION at $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown-sha)"
set +e
"${CMD[@]}" > "$WORK/out.txt" 2>&1
RC=$?
set -e

# Mask before anything leaves the job, then strip colour codes for a readable log.
sed -E -e 's/\x1b\[[0-9;]*m//g' -e 's/\b[A-Za-z0-9_-]{32,}\b/[masked]/g' "$WORK/out.txt" > "$WORK/clean.txt"
cat "$WORK/clean.txt"

LINE="$(grep -E "$SUMMARY" "$WORK/clean.txt" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "FAILED: $ACTION ended (exit $RC) without its summary line, so it examined nothing provable." >&2
  exit 1
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016 # the backticks are Markdown, not a command
  printf '### %s\n\n`%s` exit %d\n' "$ACTION" "$LINE" "$RC" >> "$GITHUB_STEP_SUMMARY"
fi
echo "lab-action: $ACTION exit $RC: $LINE"
exit "$RC"
