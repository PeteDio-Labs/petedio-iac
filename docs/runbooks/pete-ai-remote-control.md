# Pete-AI Remote Control server

Pete-AI runs `claude remote-control` as the scheduled task **Claude Remote Control**. The
server keeps Pete-AI's sessions reachable from your other devices for as long as you are
signed in to Pete-AI. Without it, a Remote Control link lives only while its session's process
runs, so Pete-AI sessions show as archived on your phone.

| Setting | Value |
| --- | --- |
| Folder | `C:\Users\pedel\goofy-skate` |
| Permission mode | `auto` |
| Spawn mode | `worktree` |
| Session name prefix | `Pete-AI` |
| CLI | `C:\Users\pedel\.local\bin\claude.exe` (not on `PATH`) |
| Logs | `%LOCALAPPDATA%\claude-remote\` |

The task is the Windows counterpart of the 247 units in `ansible/roles/claude-code/templates/`
(`claude-remote.service.j2` and `claude-ops-pm-serve.j2`). The rules in their headers apply
here too: every flag goes after `remote-control`, and no telemetry opt-out variable is set.

## How it runs

1. At your logon, after a one-minute delay, the task starts
   `conhost.exe --headless powershell.exe -File %LOCALAPPDATA%\claude-remote\claude-remote-serve.ps1`.
   The CLI gets a console, but no window appears.
1. The serve script checks the CLI, the folder, the Remote Control consent and the folder's
   trust. If any check fails, it writes the reason to `serve.log` and exits non-zero. It never
   answers a prompt itself.
1. It exits 0 if another `claude.exe remote-control` from the CLI path is already running. It
   matches the executable path, because the desktop app's processes are also named `claude.exe`.
1. It waits up to 10 minutes for `api.anthropic.com` to resolve.
1. It runs `remote-control --continue` to reattach to the last session. That reattaches only
   within about 4 hours. When the attempt ends, for any reason, it starts a fresh server with
   `--spawn worktree`.
1. When the fresh server exits, the script starts the loop again after 30 seconds. Five exits
   within five minutes end the script with exit 5.

The task runs with your interactive token. It never stores your password, so it stops when you
sign out. On failure, Task Scheduler restarts it every minute, up to 3 times.

## Set it up

To set up the server on Pete-AI, complete these steps once.

1. Answer the Remote Control consent prompt by hand. The serve script refuses to start until
   `~/.claude.json` records `remoteDialogSeen`.

   ```powershell
   cd C:\Users\pedel\goofy-skate
   & "$env:USERPROFILE\.local\bin\claude.exe" remote-control
   ```

   Answer `y`, wait for the server to print its session link, then press **Ctrl+C**.

1. Turn off hibernation on AC power. Pete-AI hibernates after 15 minutes by default, which ends
   the server. From an administrator terminal, run:

   ```powershell
   powercfg /change hibernate-timeout-ac 0
   ```

1. From the repo checkout, install the task. The script needs no administrator rights.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\pete-ai\install-claude-remote-task.ps1
   ```

   The script copies `claude-remote-serve.ps1` to `%LOCALAPPDATA%\claude-remote\`, registers
   the task, reads it back and checks each setting. A setting that doesn't read back as set
   makes it exit 1.

1. Start the task without signing out:

   ```powershell
   Start-ScheduledTask -TaskName 'Claude Remote Control'
   ```

1. On your phone, open the Claude app's session list. A `Pete-AI` server appears within about
   a minute.

To change the serve script, edit it in the repo and run the install script again. The task runs
the copy in `%LOCALAPPDATA%`, never the checkout.

## Stop the server

To stop the server, stop the task:

```powershell
Stop-ScheduledTask -TaskName 'Claude Remote Control'
```

`Stop-ScheduledTask` ends `conhost.exe`, the task's own process, and leaves the serve script
running. The script checks its console host every 5 seconds. When the host is gone, it stops the
server and its session processes, writes a line to `serve.log`, and exits. Allow 10 seconds.

If a server still runs after that, stop the serve script and the CLI's processes directly:

```powershell
Get-CimInstance Win32_Process |
    Where-Object { ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'claude-remote-serve\.ps1') -or
                   ($_.ExecutablePath -ieq "$env:USERPROFILE\.local\bin\claude.exe" -and
                    $_.CommandLine -match '\sremote-control(\s|$)|\s--sdk-url\s') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
```

The filter matches the serve script, the CLI's `remote-control` server, and the session
processes the server spawns, which carry `--sdk-url`. It leaves the desktop app and your
interactive sessions running.

When the server exits on its own, the serve script stops the session processes it leaves
behind before it starts the next server. `serve.log` records the PID and executable name of
each one it stops, never the command line, which can carry a token.

To keep the server from starting at your next logon, disable the task:

```powershell
Disable-ScheduledTask -TaskName 'Claude Remote Control'
```

To remove the task, run the install script with `-Uninstall`. It leaves the logs in place.

## Logs

All logs are in `%LOCALAPPDATA%\claude-remote\`.

| File | Contents |
| --- | --- |
| `serve.log` | One line for each start, preflight failure, attempt and exit, with the exit code. |
| `run-resume.out.log`, `run-resume.err.log` | The CLI's output from the last `--continue` attempt. |
| `run-fresh.out.log`, `run-fresh.err.log` | The CLI's output from the last fresh server. |
| `claude-debug.log` | The CLI's debug file. |

To read the task's own record, run
`Get-ScheduledTaskInfo -TaskName 'Claude Remote Control'`. `LastTaskResult` holds the serve
script's exit code. `267009` means the task is still running.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `serve.log` says `FAIL (exit 2)` and names `remoteDialogSeen` | You haven't answered the consent prompt. Complete step 1 of the setup. |
| `serve.log` says `FAIL (exit 3)` | `~/.claude.json` doesn't trust the folder. Run `claude` by hand in the folder and accept the trust prompt. |
| `serve.log` says `FAIL (exit 4)` | `api.anthropic.com` didn't resolve within 10 minutes. Check the network, then start the task. |
| `serve.log` says `FAIL (exit 5)` | The server exited 5 times in 5 minutes. An expired login is the usual cause. Read `run-fresh.err.log`, sign in with `claude` by hand, then start the task. |
| `serve.log` says a server already runs, and no `Pete-AI` server shows on your phone | A `remote-control` process from the CLI path is stuck, often at a prompt. Stop it, as described in "Stop the server", then start the task. |
| The task shows **Running**, but `serve.log` has no line for the start | `conhost.exe --headless` didn't start PowerShell. Change the task's action to `powershell.exe -WindowStyle Minimized -NoProfile -ExecutionPolicy Bypass -File <serve script>`, which shows a minimized window instead. |
| The server disappears after Pete-AI is idle | Pete-AI slept or hibernated. Run `powercfg /query SCHEME_CURRENT SUB_SLEEP` and check that sleep and hibernation on AC are `0`. |
| Sessions reconnect as new sessions after a restart | `--continue` reattaches only within about 4 hours. Past that, the script starts a fresh server, which is expected. |

Don't set `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or
`DISABLE_GROWTHBOOK` on Pete-AI. Each turns off the feature-flag check that Remote Control
depends on, so the server starts and then reports the feature as unavailable.
