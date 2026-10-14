# install-claude-remote-task.ps1: install Pete-AI's Remote Control server as the scheduled
# task "Claude Remote Control". The task runs claude-remote-serve.ps1 at your logon, with no
# window, for as long as you stay signed in.
#
#   install-claude-remote-task.ps1              # copy the serve script, register the task, verify it
#   install-claude-remote-task.ps1 -Uninstall   # unregister the task; logs stay in place
#
# Run it as the user who signs in to Pete-AI, from Windows PowerShell 5.1 or later. It needs no
# administrator rights. The runbook is docs/runbooks/pete-ai-remote-control.md.
#
# INTERACTIVE TOKEN, NO STORED PASSWORD. The task runs only while you are signed in, and it
# never asks for or stores your password.
#
# VERIFY WHAT WAS REGISTERED. This script reads the task back, checks each setting it set,
# and exits 1 on any mismatch.
param(
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$taskName = 'Claude Remote Control'
$installDir = Join-Path $env:LOCALAPPDATA 'claude-remote'
$source = Join-Path $PSScriptRoot 'claude-remote-serve.ps1'
$target = Join-Path $installDir 'claude-remote-serve.ps1'
$user = "$env:USERDOMAIN\$env:USERNAME"
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Stop-WithError([string]$Message) {
    Write-Error -Message "FAIL: $Message" -ErrorAction Continue
    exit 1
}

if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Output "No task named '$taskName' is registered; nothing to remove."
        exit 0
    }
    Stop-ScheduledTask -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-WithError "the task '$taskName' is still registered after Unregister-ScheduledTask."
    }
    Write-Output "Removed the task '$taskName'. Logs stay in $installDir."
    Write-Output "The serve script stops its server within 10 seconds. If one still runs, see the runbook's 'Stop the server' section."
    exit 0
}

foreach ($path in @($source, $conhost, $powershell)) {
    if (-not (Test-Path $path)) { Stop-WithError "no file at $path" }
}

# Copy the serve script out of the checkout, so a branch switch in the repo can't change what runs.
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -Path $source -Destination $target -Force
$sourceHash = (Get-FileHash -Path $source -Algorithm SHA256).Hash
$targetHash = (Get-FileHash -Path $target -Algorithm SHA256).Hash
if ($sourceHash -ne $targetHash) { Stop-WithError "the copy at $target does not match $source" }
Write-Output "Copied the serve script to $target (SHA256 $sourceHash)."

# conhost --headless gives the CLI a console with no window, so nothing appears on the desktop.
$arguments = "--headless `"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$target`""
$action = New-ScheduledTaskAction -Execute $conhost -Argument $arguments -WorkingDirectory $installDir

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT1M'

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# Zero for ExecutionTimeLimit means no limit. The restart settings act only when the serve
# script exits non-zero, which it does for a failed preflight or five fast exits.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Runs claude remote-control for Pete-AI. See petedio-iac docs/runbooks/pete-ai-remote-control.md.' `
    -Force | Out-Null

# Read the task back and compare each setting. Every check prints what it read.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) { Stop-WithError "Register-ScheduledTask returned, but no task named '$taskName' exists." }

$checks = @(
    @{ Name = 'action executable';    Want = $conhost;      Got = $task.Actions[0].Execute },
    @{ Name = 'action arguments';     Want = $arguments;    Got = $task.Actions[0].Arguments },
    @{ Name = 'trigger delay';        Want = 'PT1M';        Got = $task.Triggers[0].Delay },
    @{ Name = 'trigger user';         Want = $user;         Got = $task.Triggers[0].UserId },
    @{ Name = 'logon type';           Want = 'Interactive'; Got = [string]$task.Principal.LogonType },
    @{ Name = 'run level';            Want = 'Limited';     Got = [string]$task.Principal.RunLevel },
    @{ Name = 'multiple instances';   Want = 'IgnoreNew';   Got = [string]$task.Settings.MultipleInstances },
    @{ Name = 'execution time limit'; Want = 'PT0S';        Got = $task.Settings.ExecutionTimeLimit },
    @{ Name = 'restart count';        Want = '3';           Got = [string]$task.Settings.RestartCount },
    @{ Name = 'restart interval';     Want = 'PT1M';        Got = $task.Settings.RestartInterval },
    @{ Name = 'start on batteries';   Want = 'False';       Got = [string]$task.Settings.DisallowStartIfOnBatteries },
    @{ Name = 'stop on batteries';    Want = 'False';       Got = [string]$task.Settings.StopIfGoingOnBatteries },
    @{ Name = 'start when available'; Want = 'True';        Got = [string]$task.Settings.StartWhenAvailable }
)
$failed = 0
foreach ($c in $checks) {
    if ($c.Got -ieq $c.Want) {
        Write-Output ("ok    {0}: {1}" -f $c.Name, $c.Got)
    } else {
        Write-Output ("WRONG {0}: want '{1}', read '{2}'" -f $c.Name, $c.Want, $c.Got)
        $failed++
    }
}
if ($failed -gt 0) { Stop-WithError "$failed of $($checks.Count) task settings did not read back as set." }

Write-Output "Registered '$taskName' and read back all $($checks.Count) settings."
Write-Output "To start it without signing out, run: Start-ScheduledTask -TaskName '$taskName'"