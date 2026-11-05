#!/usr/bin/env bash
# lab-action — run one allowlisted lab action from the homelab runner (PET-861).
#
#   scripts/lab-action.sh lab_verify    # scripts/lab-verify.sh --quiet
#   scripts/lab-action.sh lab_updates   # scripts/lab-updates.sh
#
# .github/workflows/lab-action.yml calls this on runner 232 when a thread dispatches it, so a
# read-back no longer needs a paste-in prompt on 247 or the Mac. Both actions only read, so they
# run with no approval. A write action belongs to a later phase and waits on the `lab-write`
# environment, which only Pedro can approve.
#
# HOW IT REACHES THE NODES. It makes a fresh ed25519 key in a temporary HOME and asks Vault to sign
# it as lab-runner (vault-config/ssh.tf). The nodes map that principal to root (roles/ssh-ca,
# group_vars for the node groups), and the certificate works only from 232, for 30 minutes. The
# key and certificate are deleted on exit. No standing key exists anywhere.
#
# WHAT IT PRINTS. The run log is public, because petedio-iac is. The scripts print status and
# counts, never values, and this wrapper masks any run of 32 or more letters, digits, `_` or `-`
# as well, which covers API keys and tokens. It also masks commit SHAs, which is the price. It exits non-zero when the action fails, when Vault refuses, and when
# the script ends without its summary line, so a run that examined nothing never reads as green.
#
# Needs: VAULT_ADDR, VAULT_CACERT and VAULT_TOKEN (the lab-action-read role), curl, python3,
# ssh-keygen and ssh.
set -euo pipefail

ACTION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The allowlist. An action not named here is refused before anything is signed.
case "$ACTION" in
  lab_verify)  CMD=("$REPO_ROOT/scripts/lab-verify.sh" --quiet); SUMMARY='^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped' ;;
  lab_updates) CMD=("$REPO_ROOT/scripts/lab-updates.sh");        SUMMARY='^examined [0-9]+ hosts or guests' ;;
  *) echo "REFUSED: '$ACTION' is not an allowlisted action (lab_verify, lab_updates)." >&2; exit 2 ;;
esac

for v in VAULT_ADDR VAULT_CACERT VAULT_TOKEN; do
  [ -n "${!v:-}" ] || { echo "ABORT: $v is not set; the job did not log in to Vault." >&2; exit 1; }
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
if ! curl -sS --fail-with-body --cacert "$VAULT_CACERT" -m 15 \
    -H "X-Vault-Token: $VAULT_TOKEN" -X POST --data @"$WORK/sign.json" \
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
curl -sS --cacert "$VAULT_CACERT" -m 10 -o /dev/null -H "X-Vault-Token: $VAULT_TOKEN" \
  -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" \
  || echo "WARN: could not revoke the Vault token; it expires at the end of its 15-minute TTL." >&2
unset VAULT_TOKEN
# lab-verify.sh skips, rather than fails, the checks this runner has no key for.
export LAB_ACTION=1

# The aliases lab-verify.sh and lab-updates.sh use, mapped to the nodes' addresses as root. pve01
# is reached by address in lab-verify.sh, so it gets a Host block by address. pi1 and the runners
# accept no lab-runner certificate, so their checks fail from here and say so in the output.
#
# Host keys: the temporary HOME has no known_hosts, so the first contact is trusted. A machine
# that answers in a node's place can feed false output but cannot reuse the certificate, which
# also pins the source address to 232.
cat > "$HOME/.ssh/config" <<EOF
Host pve02
  HostName 192.168.50.11
Host pve03
  HostName 192.168.50.10
Host 192.168.50.12
  HostName 192.168.50.12
Host pve02 pve03 192.168.50.12
  User root
  IdentityFile $HOME/.ssh/lab_runner
  CertificateFile $HOME/.ssh/lab_runner-cert.pub
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $HOME/.ssh/known_hosts
EOF

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
