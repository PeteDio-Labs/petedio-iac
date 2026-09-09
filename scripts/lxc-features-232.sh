#!/usr/bin/env bash
# lxc-features-232.sh — restore `features` (nesting + keyctl) on runner-232, the pve03
# CI runner, out-of-band on the Proxmox node as root@pam. (PET-364)
#
# WHY THIS ISN'T TERRAFORM / AN API TOKEN:
#   Proxmox enforces a hardcoded `user == root@pam` check for the LXC features{}
#   mutation. An API token's username is `root@pam!tokenid`, not `root@pam`, so it
#   fails — even for a PVEAdmin token (docs/GOTCHAS.md). So bpg/proxmox creates the
#   LXC WITHOUT a features{} block (kept in ignore_changes), and this script applies
#   nesting=1,keyctl=1 the only way that works: `pct set` as root@pam on the node.
#
# WHAT BREAKS WITHOUT IT: an unprivileged LXC cannot mount overlayfs, so EVERY Docker
# image pull fails — service containers and `docker build` alike:
#   mount source: "overlay" ... err: permission denied
#   ##[error]Docker pull failed with exit code 1
# Measured 2026-09-06: CT 233 (features set) pulls postgres:17 fine, CT 232 (features
# absent) cannot. Same Docker version, same snapshotter. That is the whole difference.
#
# ⚠⚠ 232 IS A LIVE CI RUNNER, UNLIKE 230/235/241. Those scripts reboot an empty or
# idle container and say so. This one reboots the box that runs app CI for the whole
# org, so a blind reboot kills whatever job is mid-flight — and a killed job looks
# like a flaky test, not like someone rebooting the runner underneath it. The script
# therefore REFUSES to reboot while the runner is busy. Override only if you know
# what is running: FORCE=1.
#
# ⚠ Terraform will never tell you this drifted. `features` is in ignore_changes by
# design, so the plan is clean whether or not the flags are there. Nor will the
# runner look unhealthy: Docker is installed, the service is up, jobs are accepted.
# Four things reported green while every containerised job on this runner failed.
#
#   pve host:  $PVE_HOST     (default 192.168.50.10 = pve03, where 232 lives)
#   pve key :  $PVE_SSH_KEY  (default ~/.ssh/id_ed25519_proxmox_pedro — bare-metal root)
#   lxc key :  $LXC_SSH_KEY  (default ~/.ssh/id_ed25519_ansible — the key TF installs)
# NB: the Proxmox NODE and the LXC use DIFFERENT keys — the node is bare metal (root via
# the proxmox key), 232 is a TF-created LXC (root via the ansible key). Don't conflate them.
#
# Idempotent: if the features are already present it verifies the pull and exits without
# touching anything.
set -euo pipefail

PVE_HOST="${PVE_HOST:-192.168.50.10}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
VMID="${VMID:-232}"
LXC_IP="${LXC_IP:-192.168.50.232}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
LXC_SSH_KEY="${LXC_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
FEATURES="nesting=1,keyctl=1"
PROBE_IMAGE="${PROBE_IMAGE:-postgres:17}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"
[ -f "$LXC_SSH_KEY" ] || die "LXC SSH key not found: $LXC_SSH_KEY"

SSH=(ssh -i "$PVE_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$PVE_SSH_USER@$PVE_HOST")
LXC=(ssh -i "$LXC_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$LXC_IP")

# The behavioural check. `pct config` tells you what is configured; this tells you
# whether the thing those flags exist to enable actually works. Only the second one
# would have caught this drift.
probe_pull() {
  "${LXC[@]}" "docker rmi $PROBE_IMAGE >/dev/null 2>&1; timeout 180 docker pull $PROBE_IMAGE >/dev/null 2>&1" \
    && return 0 || return 1
}

step "Reading current features of LXC $VMID on $PVE_HOST"
CFG="$("${SSH[@]}" "pct config $VMID" 2>/dev/null)" || die "cannot read pct config $VMID on $PVE_HOST (is $VMID on this node? is SSH-as-root working?)"
CUR_FEATURES="$(printf '%s\n' "$CFG" | sed -nE 's/^features:[[:space:]]*//p')"
echo "  current: features: ${CUR_FEATURES:-<none>}"

if printf '%s' "$CUR_FEATURES" | grep -q 'nesting=1' && printf '%s' "$CUR_FEATURES" | grep -q 'keyctl=1'; then
  step "Already set — verifying the pull actually works before declaring victory"
  if probe_pull; then
    echo "  docker pull $PROBE_IMAGE OK — nothing to do."
    exit 0
  fi
  die "features are set but 'docker pull $PROBE_IMAGE' still fails. Something else is wrong — do NOT reboot blindly; inspect the storage driver and dmesg on $LXC_IP."
fi

# ⚠ THE GUARD THAT THE 230/235/241 SCRIPTS DO NOT NEED. Rebooting a busy CI runner
# kills the job on it, and the resulting red check reads as a flaky test.
step "Checking whether runner-232 is mid-job"
# ⚠ THE BRACKET IS LOAD-BEARING: [R]unner. `pgrep -f` matches full command lines, and
# the command line carrying this pattern over SSH is itself a process on the target —
# so a plain "Runner\.Worker" MATCHES ITSELF and the guard reports "busy" forever.
# Caught on the first real run of this script, where it refused to proceed against an
# idle runner with no job in flight anywhere in the org. A guard that always fires is
# the same as no guard: you learn to pass FORCE=1 without reading it.
#
# Matching the WORKER, not the listener: Runner.Listener is the idle daemon and is
# always running. Only Runner.Worker means a job is actually executing.
BUSY="$("${LXC[@]}" 'pgrep -fa "[R]unner\.Worker" >/dev/null 2>&1 && echo busy || echo idle' 2>/dev/null || echo unknown)"
case "$BUSY" in
  busy)
    if [ "${FORCE:-0}" != "1" ]; then
      die "runner-232 is RUNNING A JOB right now. Rebooting would kill it and the failure would look like a flaky test. Wait for it to finish, or re-run with FORCE=1 if you know what is on it."
    fi
    warn "  runner is busy, but FORCE=1 was set — the in-flight job WILL die."
    ;;
  idle)    echo "  idle — safe to reboot." ;;
  unknown) warn "  could not determine runner state over SSH; continuing (the container is about to reboot anyway)." ;;
esac

step "Setting features=$FEATURES on LXC $VMID"
"${SSH[@]}" "pct set $VMID --features $FEATURES" || die "pct set failed."

step "Rebooting LXC $VMID so the new features take effect"
"${SSH[@]}" "pct reboot $VMID" || {
  echo "  pct reboot did not complete cleanly; falling back to stop/start"
  "${SSH[@]}" "pct stop $VMID || true; sleep 3; pct start $VMID"
}

step "Waiting for $VMID to answer SSH on $LXC_IP (LXC key, not the pve key)"
for i in $(seq 1 30); do
  if "${LXC[@]}" true 2>/dev/null; then echo "  up after ${i} tries"; break; fi
  [ "$i" = 30 ] && die "container $VMID did not come back on $LXC_IP after the reboot."
  sleep 4
done

step "Confirming features applied"
NEW="$("${SSH[@]}" "pct config $VMID" | sed -nE 's/^features:[[:space:]]*//p')"
echo "  now: features: ${NEW:-<none>}"
printf '%s' "$NEW" | grep -q 'nesting=1' && printf '%s' "$NEW" | grep -q 'keyctl=1' \
  || die "features not present after set — inspect manually."

# ⚠ The config string is not the outcome. This is.
step "Proving the thing that was actually broken: docker pull $PROBE_IMAGE"
probe_pull || die "features are set but 'docker pull $PROBE_IMAGE' STILL fails — the diagnosis was incomplete. Inspect the storage driver and dmesg on $LXC_IP before closing PET-364."
echo "  docker pull $PROBE_IMAGE OK"

step "Confirming the Actions runner came back"
"${LXC[@]}" 'systemctl is-active --quiet "actions.runner.*" && echo "  runner service active" || echo "  ⚠ runner service NOT active — check systemctl on 232"' 2>/dev/null || \
  warn "  could not query the runner service; check it manually."

step "Done — LXC $VMID has $FEATURES and can pull images again."
