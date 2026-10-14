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

Write-Log "Starting: workdir=$WorkDir prefix=$NamePrefix mode=$PermissionMode spawn=$Spawn"

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

function Invoke-Claude([string]$Label, [string[]]$Arguments) {
    $p = Start-Process -FilePath $claude -ArgumentList $Arguments -WorkingDirectory $WorkDir `
        -NoNewWindow -Wait -PassThru -RedirectStandardInput $noInput `
        -RedirectStandardOutput (Join-Path $logDir "run-$Label.out.log") `
        -RedirectStandardError (Join-Path $logDir "run-$Label.err.log")
    return $p.ExitCode
}

$exits = New-Object System.Collections.Generic.List[datetime]
while ($true) {
    Write-Log 'Resume attempt: remote-control --continue'
    $rc = Invoke-Claude 'resume' (@('remote-control', '--continue') + $common)
    Write-Log "The resume attempt ended (exit $rc); starting a fresh server."

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
