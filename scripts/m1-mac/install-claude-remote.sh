#!/bin/bash
# install-claude-remote.sh: install the Mac's Remote Control server as the LaunchAgent
# dev.pdlab.claude-remote (PET-622). docs/runbooks/m1-mac-remote-control.md covers the steps
# before and after it.
#
#   install-claude-remote.sh               install, or reinstall, and start the server
#   install-claude-remote.sh --uninstall   stop the server and remove the agent and its copy
#
# Run it as yourself, never with sudo: the agent belongs to your login session.
#
# AN INSTALLED COPY, NOT THE CLONE. The iac clone switches branches, so the agent runs a copy
# of claude-remote-serve.sh under ~/Library/Application Support/claude-remote/. Run this
# script again after the wrapper changes on main.
#
# READ IT BACK. After the bootstrap, this script reads the plist's settings, the copy's sha256
# and launchd's own record of the job. Any mismatch exits 1.
set -euo pipefail

label="${CLAUDE_REMOTE_LABEL:-dev.pdlab.claude-remote}"
uid="$(id -u)"
domain="gui/$uid"
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/claude-remote-serve.sh"
appdir="$HOME/Library/Application Support/claude-remote"
dest="$appdir/claude-remote-serve.sh"
plist="$HOME/Library/LaunchAgents/$label.plist"
logdir="$HOME/Library/Logs/claude-remote"
path_env="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

die() { printf 'install-claude-remote: %s\n' "$*" >&2; exit 1; }

[ "$uid" -ne 0 ] || die "run this as yourself, not as root."

stop_agent() {
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label" || die "launchctl bootout $domain/$label failed."
    # bootout returns before launchd drops the job, which waits up to ExitTimeOut (30 s).
    local i=0
    while launchctl print "$domain/$label" >/dev/null 2>&1; do
      i=$((i + 1))
      [ "$i" -le 40 ] || die "launchd still lists $label 40 seconds after bootout."
      sleep 1
    done
    echo "Stopped $label."
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  stop_agent
  rm -f "$plist" "$dest"
  rmdir "$appdir" 2>/dev/null || true
  [ ! -e "$plist" ] && [ ! -e "$dest" ] || die "a file is left behind: $plist or $dest."
  if launchctl print "$domain/$label" >/dev/null 2>&1; then die "launchd still lists $label."; fi
  echo "Uninstalled $label. The logs stay in $logdir."
  exit 0
fi
[ $# -eq 0 ] || die "usage: $0 [--uninstall]"

[ -f "$src" ] || die "no wrapper at $src."

# Stop any running copy first, so the preflight's one-server check doesn't pass on it.
stop_agent

mkdir -p "$appdir" "$logdir" "$(dirname "$plist")"
install -m 0755 "$src" "$dest"

# The preflight refuses to install an agent that would fail at login.
/bin/bash "$dest" --check || die "the preflight failed. Read $logdir/serve.log, fix it, then run this again."

cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by iac/scripts/m1-mac/install-claude-remote.sh (PET-622). Edit that script, not this file. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$dest</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ExitTimeOut</key>
  <integer>30</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>$path_env</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$logdir/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$logdir/launchd.log</string>
</dict>
</plist>
EOF
plutil -lint "$plist" >/dev/null || die "plutil rejects $plist."

launchctl bootstrap "$domain" "$plist" || die "launchctl bootstrap $domain $plist failed."

# Read back every setting.
bad=0
expect() {
  local got
  got="$(plutil -extract "$1" raw -o - "$plist" 2>/dev/null)" || got="<missing>"
  if [ "$got" != "$2" ]; then
    echo "MISMATCH $1: '$got', expected '$2'"
    bad=1
  fi
}
expect Label "$label"
expect ProgramArguments.0 /bin/bash
expect ProgramArguments.1 "$dest"
expect RunAtLoad true
expect KeepAlive false
expect LimitLoadToSessionType Aqua
expect EnvironmentVariables.HOME "$HOME"
expect EnvironmentVariables.PATH "$path_env"

want="$(shasum -a 256 "$src" | cut -d' ' -f1)"
got="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
if [ "$want" != "$got" ]; then
  echo "MISMATCH sha256 of $dest: $got, expected $want"
  bad=1
fi

if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
  echo "MISMATCH launchd does not list $domain/$label"
  bad=1
fi

[ "$bad" -eq 0 ] || die "the read-back found a mismatch."

sleep 3
state="$(launchctl print "$domain/$label" | awk -F' = ' '/^\tstate/ {print $2; exit}')"
echo "Installed $label: copy sha256 $got, launchd state '${state:-unknown}'."
echo "Server log: $logdir/serve.log"
