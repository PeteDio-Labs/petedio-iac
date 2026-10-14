# claude-remote-serve.ps1: Pete-AI's Remote Control server, the Windows counterpart of
# claude-ops-pm-serve.j2 on LXC 247. The scheduled task "Claude Remote Control" runs it at
# logon through `conhost.exe --headless`, so the server has a console but no window.
#
#   claude-remote-serve.ps1 [-WorkDir <dir>] [-NamePrefix <name>] [-PermissionMode <mode>] [-Spawn <mode>]
#
# Logs go to %LOCALAPPDATA%\claude-remote\: serve.log (this script), run-*.log (the CLI's
# output for the last resume and fresh attempt) and claude-debug.log (the CLI's debug file).
#
# FAIL LOUDLY BEFORE STARTING. A unit with no terminal hangs on any interactive prompt (247
# hung for two days on 2026-09-12). So this script refuses to start, with a non-zero exit and a
# line in serve.log, until the Remote Control consent and the folder's trust prompt are answered
# by hand. It does not answer them itself.
#
# RESUME FIRST, THEN START FRESH. `remote-control --continue` reattaches to the session this
# directory last recorded, but only within roughly 4 hours. Its exit code is not trusted (see
# claude-ops-pm-serve.j2), so any exit of the resume attempt starts a fresh server.
#
# BOUNDED RESTART. An expired login makes the CLI exit at once. Five exits within five minutes
# end this script with exit 5 instead of looping forever.
#
# A DEAD SERVER'S SESSIONS GO WITH IT. When a server exits, this script stops the session
# processes it leaves behind, then starts the next server. The next server's `--continue`
# reattaches the session, so a survivor would be a second process on it. The cost is any turn
# that was in flight when the server died.
#
# STOPPING THE TASK STOPS THE SCRIPT. Stop-ScheduledTask ends conhost.exe, the task's own
# process, and leaves this script running. On 2026-10-14 an orphaned copy kept looping, and every
# launch failed with 0xC0000142 because its console was gone. So the script watches its console
# host: when the host is gone, it stops the server and its session processes, then exits 0.
param(
    [string]$WorkDir = (Join-Path $env:USERPROFILE 'goofy-skate'),
    [string]$NamePrefix = 'Pete-AI',
    [string]$PermissionMode = 'auto',
    [string]$Spawn = 'worktree'
)
$ErrorActionPreference = 'Stop'

$claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$logDir = Join-Path $env:LOCALAPPDATA 'claude-remote'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'serve.log'
# An empty file stands in for /dev/null: a prompt reads end-of-input and exits instead of hanging.
$noInput = Join-Path $logDir 'stdin-empty.txt'
Set-Content -Path $noInput -Value $null -NoNewline

function Write-Log([string]$Message) {
    Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 's'), $Message) -Encoding UTF8
}

function Stop-WithError([int]$Code, [string]$Message) {
    Write-Log "FAIL (exit $Code): $Message"
    exit $Code
}

# The console host that started this script: conhost.exe under the task, or your shell when you
# run it by hand. Holding its handle makes HasExited exact even if Windows reuses the PID.
$hostId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
$hostProc = Get-Process -Id $hostId -ErrorAction SilentlyContinue
if ($hostProc) { $null = $hostProc.Handle }

function Test-HostGone {
    return (-not $hostProc) -or $hostProc.HasExited
}

function Exit-IfHostGone {
    if (Test-HostGone) {
        Write-Log "The console host (pid $hostId) is gone, so the task was stopped; exiting."
        exit 0
    }
}

Write-Log "Starting: workdir=$WorkDir prefix=$NamePrefix mode=$PermissionMode spawn=$Spawn host=$hostId"

# Preflight. Each check names what it read, so "not found" and "not checked" can't look alike.
if (-not (Test-Path $claude)) { Stop-WithError 1 "no Claude CLI at $claude" }
if (-not (Test-Path $WorkDir)) { Stop-WithError 1 "no working folder at $WorkDir" }

$configPath = Join-Path $env:USERPROFILE '.claude.json'
if (-not (Test-Path $configPath)) { Stop-WithError 2 "no $configPath; sign in to the Claude CLI first" }
$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
if (-not $config.remoteDialogSeen) {
    Stop-WithError 2 ("$configPath has no remoteDialogSeen. To answer the consent prompt, run " +
        "'claude remote-control' by hand in $WorkDir, answer y, then press Ctrl+C.")
}
$projectKey = ($WorkDir -replace '\\', '/').TrimEnd('/')
$project = $config.projects.PSObject.Properties | Where-Object { $_.Name -ieq $projectKey } | Select-Object -First 1
if (-not $project -or -not $project.Value.hasTrustDialogAccepted) {
    Stop-WithError 3 ("$configPath does not trust $projectKey. To trust it, run 'claude' by hand " +
        "in $WorkDir and accept the trust prompt.")
}

# One server per user. The desktop app is also claude.exe, so match the CLI's path and verb.
$running = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
    Where-Object { $_.ExecutablePath -ieq $claude -and $_.CommandLine -match '\sremote-control(\s|$)' }
if ($running) {
    Write-Log ("A Remote Control server already runs (pid {0}); exiting." -f (($running | ForEach-Object ProcessId) -join ','))
    exit 0
}

# Wait for DNS, so a network outage at logon doesn't fail the task. 10-minute cap.
$deadline = (Get-Date).AddMinutes(10)
while ($true) {
    try { Resolve-DnsName -Name 'api.anthropic.com' -QuickTimeout -ErrorAction Stop | Out-Null; break }
    catch {
        if ((Get-Date) -gt $deadline) { Stop-WithError 4 'api.anthropic.com did not resolve within 10 minutes' }
        Start-Sleep -Seconds 10
    }
}

# Every flag goes AFTER `remote-control`: a global flag before it stops the CLI from starting.
$common = @('--permission-mode', $PermissionMode,
            '--remote-control-session-name-prefix', $NamePrefix,
            '--debug-file', (Join-Path $logDir 'claude-debug.log'))

# Quote one argument by the Windows command-line rules. Windows PowerShell 5.1 joins an
# -ArgumentList array with spaces and no quoting, so a value with a space splits in two.
function ConvertTo-ArgToken([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'   # double the backslashes before a quote, escape it
    $escaped = $escaped -replace '(\\+)$', '$1$1'   # double a trailing run before the closing quote
    return '"' + $escaped + '"'
}

# Stop what a server left behind. Windows doesn't reparent orphans, so a session process still
# names the dead server as its parent. The CreationDate check skips a process that reused a PID.
function Stop-Descendants([int]$RootId, [datetime]$NotBefore) {
    $all = @(Get-CimInstance Win32_Process)
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $parent -and $_.CreationDate -ge $NotBefore }) {
            $queue.Enqueue([int]$child.ProcessId)
            # The name only, never CommandLine: a session's command can carry a token.
            Write-Log ("Stopping pid {0} ({1}, parent pid {2}), left behind by server pid {3}" -f $child.ProcessId, $child.Name, $parent, $RootId)
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Claude([string]$Label, [string[]]$Arguments) {
    $argLine = ($Arguments | ForEach-Object { ConvertTo-ArgToken $_ }) -join ' '
    $notBefore = (Get-Date).AddSeconds(-1)
    # No -Wait: in 5.1 it waits for the whole process tree, so a surviving session process would
    # hold this call open after the server died, and the loop would never restart it.
    $p = Start-Process -FilePath $claude -ArgumentList $argLine -WorkingDirectory $WorkDir `
        -NoNewWindow -PassThru -RedirectStandardInput $noInput `
        -RedirectStandardOutput (Join-Path $logDir "run-$Label.out.log") `
        -RedirectStandardError (Join-Path $logDir "run-$Label.err.log")
    # 5.1 reports no ExitCode unless the handle is opened before the process exits.
    $null = $p.Handle
    # Check the console host every 5 seconds, so Stop-ScheduledTask stops the server too.
    while (-not $p.WaitForExit(5000)) {
        if (Test-HostGone) {
            Write-Log "The console host (pid $hostId) is gone, so the task was stopped; stopping server pid $($p.Id)."
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Stop-Descendants $p.Id $notBefore
            Exit-IfHostGone
        }
    }
    $rc = $p.ExitCode
    Stop-Descendants $p.Id $notBefore
    return $rc
}

$exits = New-Object System.Collections.Generic.List[datetime]
while ($true) {
    Exit-IfHostGone
    Write-Log 'Resume attempt: remote-control --continue'
    $rc = Invoke-Claude 'resume' (@('remote-control', '--continue') + $common)
    Write-Log "The resume attempt ended (exit $rc); starting a fresh server."
    Exit-IfHostGone

    $rc = Invoke-Claude 'fresh' (@('remote-control', '--spawn', $Spawn) + $common)
    Write-Log "The fresh server ended (exit $rc)."

    $now = Get-Date
    $exits.Add($now)
    $exits.RemoveAll([Predicate[datetime]] { param($t) $t -lt $now.AddMinutes(-5) }) | Out-Null
    if ($exits.Count -ge 5) {
        Stop-WithError 5 ("the server exited 5 times in 5 minutes. Read run-fresh.err.log and " +
            "claude-debug.log; an expired login is the usual cause.")
    }
    Start-Sleep -Seconds 30
}
