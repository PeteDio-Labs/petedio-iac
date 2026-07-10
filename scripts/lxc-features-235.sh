#!/usr/bin/env bash
# lxc-features-235.sh — set nesting=1,keyctl=1 on the Palworld control-panel LXC 235 so
# Docker can run inside the unprivileged container (PET-266). Thin wrapper around the
# parametric lxc-features-230.sh (same root@pam/API-token gotcha; see that script + GOTCHAS.md).
# Touches ONLY container 235; idempotent (no change / no reboot if already set).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env VMID=235 LXC_IP="${LXC_IP:-192.168.50.235}" "$SCRIPT_DIR/lxc-features-230.sh" "$@"
