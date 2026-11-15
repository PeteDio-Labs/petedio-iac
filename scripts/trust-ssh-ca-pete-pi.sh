#!/usr/bin/env bash
# trust-ssh-ca-pete-pi.sh — make pete-pi accept the deploy-uptime-kuma SSH certificate (PET-849).
#
# Run once from the Mac or claude-247, with your own key for pedro@192.168.50.4. It places no
# credential: it fetches the Vault SSH CA public key, which Vault serves unauthenticated, and
# writes three files on the Pi. Nothing is stored in Vault and no runner key exists.
#
# WHAT IT CHANGES on pete-pi:
#   /etc/ssh/trusted-user-ca-keys.pem        the CA public key
#   /etc/ssh/auth_principals/pedro           the one line `deploy-uptime-kuma`
#   /etc/ssh/sshd_config.d/10-ssh-ca.conf    TrustedUserCAKeys and AuthorizedPrincipalsFile
# It never edits authorized_keys, so the key you use to run this still logs in afterward. `sshd -t`
# gates the drop-in, and a rejected drop-in is removed before sshd reloads. The script then proves
# the result by reading sshd's effective config and the listener count.
#
# ansible/inventory/host_vars/pete-pi.yml declares the same state for roles/ssh-ca, so a later
# configure-ssh-ca.yml run on this host keeps these files.
#
# PRINCIPAL SCOPE. AuthorizedPrincipalsFile applies to every user, so root and other accounts on the
# Pi get no principals file and trust no certificate. Only pedro lists a principal.
#
# Prints what it examined. Exits non-zero on any failure, including a Vault that is sealed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
CA_CERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"
PI="${PI_HOST:-pedro@192.168.50.4}"
PRINCIPAL="deploy-uptime-kuma"

die(){ printf 'ABORT: %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die "curl not in PATH"
[ -f "$CA_CERT" ] || die "Vault CA file not found: $CA_CERT"

echo "== Vault: read the SSH CA public key"
CA_KEY="$(curl -fsS --cacert "$CA_CERT" "$VAULT_ADDR/v1/ssh-client-signer/public_key" | tr -d '\r')" \
  || die "could not read the CA key. Is Vault sealed?"
[ "$(printf '%s\n' "$CA_KEY" | wc -l)" -eq 1 ] && printf '%s\n' "$CA_KEY" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+$' \
  || die "Vault returned no usable one-line ssh-ed25519 CA key with no comment."
echo "  read one ssh-ed25519 key"

echo "== pete-pi: trust the CA and list $PRINCIPAL for pedro"
# The CA public key is not a secret, so it travels as an argument. The script itself is stdin.
ssh -o BatchMode=yes "$PI" "sudo sh -s -- '$PRINCIPAL' '$CA_KEY'" <<'REMOTE'
set -eu
principal="$1"
ca_file=/etc/ssh/trusted-user-ca-keys.pem
pdir=/etc/ssh/auth_principals
dropin=/etc/ssh/sshd_config.d/10-ssh-ca.conf
ca_key="$2"
mkdir -p "$pdir" "$(dirname "$dropin")"
land() {
  f="$1"; printf '%s\n' "$2" > "$f.new"
  if cmp -s "$f.new" "$f"; then rm -f "$f.new"; printf unchanged
  else chmod 0644 "$f.new"; mv "$f.new" "$f"; printf changed; fi
}
r_ca="$(land "$ca_file" "$ca_key")"
r_pr="$(land "$pdir/pedro" "$principal")"
r_dr="$(land "$dropin" "# Managed by petedio-iac scripts/trust-ssh-ca-pete-pi.sh (PET-849).
TrustedUserCAKeys $ca_file
AuthorizedPrincipalsFile $pdir/%u")"
if ! /usr/sbin/sshd -t; then
  rm -f "$dropin"
  /usr/sbin/sshd -t
  echo "REJECTED: sshd -t refused the drop-in; removed it"
  exit 1
fi
if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.service
else systemctl reload ssh.service; fi
eff="$(/usr/sbin/sshd -T | grep -cE "^(trustedusercakeys $ca_file|authorizedprincipalsfile $pdir/%u)$" || true)"
n=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  n="$(ss -H -ltn 'sport = :22' | grep -c LISTEN || true)"
  [ "$n" -gt 0 ] && break
  sleep 2
done
echo "ca=$r_ca principals=$r_pr dropin=$r_dr sshd_effective=$eff/2 listeners=$n"
[ "$eff" -eq 2 ] && [ "$n" -gt 0 ]
REMOTE
echo "== Done: dispatch deploy-uptime-kuma.yml on main. The first run is the first certificate login."
