[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TaskName = 'iBacalao Homework Agent'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvPath = Join-Path $RepoRoot '.env'
$NodeCli = Join-Path $RepoRoot 'node_modules\tsx\dist\cli.mjs'
$WorkerEntry = Join-Path $RepoRoot 'src\ping.ts'

if ($env:OS -ne 'Windows_NT') {
    throw 'This setup command only runs on Windows.'
}

$nodeCommand = Get-Command 'node.exe' -ErrorAction Stop
$NodePath = $nodeCommand.Source
$nodeVersionText = (& $NodePath --version).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Could not run Node.js. Install Node.js 20.12 or newer and retry.'
}
try {
    $nodeVersion = [version]($nodeVersionText -replace '^v', '')
} catch {
    throw 'Could not read the installed Node.js version.'
}
if ($nodeVersion -lt [version]'20.12.0') {
    throw 'Node.js 20.12 or newer is required. Install a supported version and retry.'
}
if (-not (Test-Path -LiteralPath $NodeCli -PathType Leaf) -or -not (Test-Path -LiteralPath $WorkerEntry -PathType Leaf)) {
    throw 'Worker dependencies are missing. Run npm ci from the Homework Automation repository, then retry.'
}
if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
    throw 'This computer is not paired. Run npm run pair first, then retry.'
}

# Read only to validate the local configuration. Never print .env values.
$envText = [System.IO.File]::ReadAllText($EnvPath)
function Test-EnvValue([string]$Content, [string]$Name) {
    foreach ($line in ($Content -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$')
        if (-not $match.Success) { continue }
        $value = $match.Groups[1].Value.Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Substring(1, $value.Length - 2) }
        if ($value.StartsWith("'") -and $value.EndsWith("'")) { $value = $value.Substring(1, $value.Length - 2) }
        return -not [string]::IsNullOrWhiteSpace($value)
    }
    return $false
}
if (-not (Test-EnvValue $envText 'IBACALAO_AGENT_TOKEN')) {
    throw 'The local worker token is missing. Run npm run pair and retry.'
}
if (-not (Test-EnvValue $envText 'IBACALAO_LLM_BASE_URL') -and -not (Test-EnvValue $envText 'IBACALAO_LLM_API_KEY')) {
    throw 'Configure IBACALAO_LLM_BASE_URL or IBACALAO_LLM_API_KEY in .env before starting the background worker.'
}

# Apply a private ACL to the file that contains the long-lived worker token.
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$envAcl = New-Object System.Security.AccessControl.FileSecurity
$envAcl.SetOwner($userSid)
$envAcl.SetAccessRuleProtection($true, $false)
$fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$envAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($userSid, $fullControl, $allow))
$envAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, $fullControl, $allow))
Set-Acl -LiteralPath $EnvPath -AclObject $envAcl

$agentDir = Join-Path $env:LOCALAPPDATA 'iBacalao\HomeworkAgent'
$stateDir = Join-Path $agentDir 'state'
$logPath = Join-Path $agentDir 'worker.log'
$launcherPath = Join-Path $agentDir 'run-worker.ps1'
New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

function ConvertTo-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

$launcherTemplate = @'
# iBacalao Windows Homework worker launcher. Managed by setup-homework-worker-windows.ps1.
$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath __REPO_ROOT__
$env:IBACALAO_STATE_DIR = __STATE_DIR__
& __NODE_PATH__ __NODE_CLI__ __WORKER_ENTRY__ *>> __LOG_PATH__
exit $LASTEXITCODE
'@
$launcherBody = $launcherTemplate.Replace('__REPO_ROOT__', (ConvertTo-PowerShellLiteral $RepoRoot))
$launcherBody = $launcherBody.Replace('__STATE_DIR__', (ConvertTo-PowerShellLiteral $stateDir))
$launcherBody = $launcherBody.Replace('__NODE_PATH__', (ConvertTo-PowerShellLiteral $NodePath))
$launcherBody = $launcherBody.Replace('__NODE_CLI__', (ConvertTo-PowerShellLiteral $NodeCli))
$launcherBody = $launcherBody.Replace('__WORKER_ENTRY__', (ConvertTo-PowerShellLiteral $WorkerEntry))
$launcherBody = $launcherBody.Replace('__LOG_PATH__', (ConvertTo-PowerShellLiteral $logPath))

if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
    $existingLauncher = [System.IO.File]::ReadAllText($launcherPath)
    if (-not $existingLauncher.Contains('Managed by setup-homework-worker-windows.ps1')) {
        throw 'An unrelated launcher already exists in the iBacalao Homework Agent folder. It was left untouched.'
    }
}
Set-Content -LiteralPath $launcherPath -Value $launcherBody -Encoding UTF8

$powerShellPath = (Get-Command 'powershell.exe' -ErrorAction Stop).Source
$taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-PowerShellLiteral $launcherPath)
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $taskArgs -WorkingDirectory $RepoRoot
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$description = 'Runs the local iBacalao draft worker for student-selected assignments. It never submits work to a school.'

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    $ownsTask = @($existingTask.Actions | Where-Object { $_.Execute -eq $powerShellPath -and $_.Arguments -and $_.Arguments.Contains($launcherPath) }).Count -gt 0
    if (-not $ownsTask) {
        throw 'The iBacalao Homework Agent task name is already used by another task. Its configuration was left untouched.'
    }
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Output 'Windows homework worker installed and started for this user.'
Write-Output 'Open https://www.ibacalao.com/homework in your browser to select an assignment and review drafts.'
Write-Output ("Worker log: " + $logPath)
