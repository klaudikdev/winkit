<#
.SYNOPSIS
    Exercises the parts of WinKit that need administrator rights against
    throwaway objects, then removes them. Run it before every release.

.DESCRIPTION
    Always runs:
      - HKLM registry apply / undo under HKLM\SOFTWARE\KlaudikWinKitTest
      - service startup changes on a temporary, never-started test service
      - scheduled task disable / enable on a temporary test task
      - power plan switch and restore
      - Windows feature state read (no change)

    Opt in with switches:
      -IncludeDns           switch DNS to Cloudflare and undo it
      -IncludeRealTweaks    apply and undo two low-risk shipped tweaks
      -IncludeRestorePoint  create a System Restore point

    Requires an elevated Windows PowerShell:
        powershell -ExecutionPolicy Bypass -File .\tools\Test-Elevated.ps1
#>
[CmdletBinding()]
param(
    [switch]$IncludeDns,
    [switch]$IncludeRealTweaks,
    [switch]$IncludeRestorePoint
)

$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\TestHelpers.ps1')

if (-not $WK.IsAdmin) {
    Write-Host 'Run this from an elevated PowerShell window.' -ForegroundColor Red
    exit 2
}

$WK.HistoryFile = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-elevated-$([guid]::NewGuid()).json"
$script:Failures = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:Failures++ }
}
function New-Tweak([string]$Id, [object[]]$Actions) {
    Register-WKTestTweak ([pscustomobject]@{ id = $Id; category = 'privacy'; title = $Id; risk = 'low'; restart = 'none'; actions = $Actions })
}
function Undo-Latest([string]$Id) {
    foreach ($e in @(Get-WKActiveHistory -RefId $Id)) { [void](Undo-WKHistoryEntry -Entry $e) }
}

Write-Host 'Protected data folder' -ForegroundColor Cyan
$probeRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "KlaudikWinKitTest-$([guid]::NewGuid())"
$decoy = Join-Path ([System.IO.Path]::GetTempPath()) "winkit-decoy-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $decoy | Out-Null
Set-Content -LiteralPath (Join-Path $decoy 'secret.txt') -Value 'must survive'
try {
    # A folder that existed before WinKit (anyone can create folders in
    # ProgramData) is moved aside, and a new one is created locked down.
    New-Item -ItemType Directory -Path $probeRoot | Out-Null
    $planted = Join-Path $probeRoot 'history.json'
    Set-Content -LiteralPath $planted -Value '[]'
    Protect-WKDirectory -Path $probeRoot
    $acl = (Get-Item -LiteralPath $probeRoot).GetAccessControl()
    Check 'owner is Administrators' ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544')
    Check 'inherited permissions are removed' $acl.AreAccessRulesProtected
    $writers = @($acl.Access | Where-Object { $_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write } |
                 ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
    Check 'only SYSTEM and Administrators can write' (-not @($writers | Where-Object { $_ -notin 'S-1-5-18', 'S-1-5-32-544' }).Count) ($writers -join ',')
    Check 'files planted beforehand are not used' (-not (Test-Path -LiteralPath $planted))
    Check 'the planted folder was moved aside, not deleted' (@(Get-ChildItem -Path "$probeRoot.untrusted-*" -Directory).Count -eq 1)
    Check 'the protected folder passes its own check' (Test-WKProtectedDirectory -Path $probeRoot)

    # Files WinKit writes into its protected folder are kept on the next start,
    # whoever owns them (without UAC, the user owns what they create).
    $own = Join-Path $probeRoot 'settings.json'
    Set-Content -LiteralPath $own -Value '{}'
    $ownAcl = (Get-Item -LiteralPath $own).GetAccessControl()
    $ownAcl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    (Get-Item -LiteralPath $own).SetAccessControl($ownAcl)
    Protect-WKDirectory -Path $probeRoot
    Check 'files WinKit wrote itself are kept' (Test-Path -LiteralPath $own)

    # A junction in place of the folder must be moved aside, never followed.
    [System.IO.Directory]::Delete($probeRoot, $true)
    & cmd.exe /c mklink /J "$probeRoot" "$decoy" | Out-Null
    Protect-WKDirectory -Path $probeRoot
    Check 'a junction is replaced by a real folder' (-not ((Get-Item -LiteralPath $probeRoot -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint))
    Check 'the junction target is untouched' (Test-Path -LiteralPath (Join-Path $decoy 'secret.txt'))
    $decoyAcl = (Get-Item -LiteralPath $decoy).GetAccessControl()
    Check 'the junction target keeps its permissions' (-not $decoyAcl.AreAccessRulesProtected)
}
catch {
    # An unexpected error must fail the run, not skip the remaining checks.
    Check 'protected folder checks ran to the end' $false $_.Exception.Message
}
finally {
    foreach ($item in @(Get-Item -Path "$probeRoot*" -Force -ErrorAction SilentlyContinue)) {
        # Links are removed on their own; real folders with their contents.
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { [System.IO.Directory]::Delete($item.FullName) }
        else { [System.IO.Directory]::Delete($item.FullName, $true) }
    }
    [System.IO.Directory]::Delete($decoy, $true)
}
Write-Host 'HKLM registry' -ForegroundColor Cyan
$t = New-Tweak 'test.hklm' @([pscustomobject]@{ type = 'registry'; path = 'HKLM\SOFTWARE\KlaudikWinKitTest\A\B'; name = 'V'; kind = 'DWord'; value = 1 })
$r = Invoke-WKTweak -Tweak $t
Check 'HKLM value written' ($r.Changed -eq 1 -and (Get-WKTweakState $t).State -eq 'Applied')
Undo-Latest 'test.hklm'
Check 'HKLM key removed on undo' (-not (Test-Path 'HKLM:\SOFTWARE\KlaudikWinKitTest'))

Write-Host 'Service startup' -ForegroundColor Cyan
$svc = 'KlaudikWinKitTest'
& sc.exe delete $svc 2>$null | Out-Null
# The service is never started; it only needs to exist so its startup type can change.
& sc.exe create $svc binPath= "$env:WINDIR\System32\svchost.exe -k KlaudikWinKitTest" start= demand DisplayName= 'Klaudik WinKit test service' | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host '  Could not create the test service' -ForegroundColor Red; $script:Failures++ }
try {
    $t = New-Tweak 'test.service' @([pscustomobject]@{ type = 'service'; name = $svc; startup = 'Disabled'; defaultStartup = 'Manual' })
    Check 'service reads Manual' ((Get-WKServiceStartup -Name $svc) -eq 'Manual')
    Invoke-WKTweak -Tweak $t | Out-Null
    Check 'service set to Disabled' ((Get-WKServiceStartup -Name $svc) -eq 'Disabled')
    Undo-Latest 'test.service'
    Check 'service restored to Manual' ((Get-WKServiceStartup -Name $svc) -eq 'Manual')
    Set-WKServiceStartup -Name $svc -Startup Disabled
    & sc.exe config $svc start= delayed-auto | Out-Null
    Check 'delayed start detected' ((Get-WKServiceStartup -Name $svc) -eq 'AutomaticDelayed')
}
finally { & sc.exe delete $svc | Out-Null }
$missing = New-Tweak 'test.missing' @([pscustomobject]@{ type = 'service'; name = 'KlaudikNoSuchService'; startup = 'Disabled'; defaultStartup = 'Manual' })
Check 'missing service is Unavailable' ((Get-WKTweakState $missing).State -eq 'Unavailable')

Write-Host 'Scheduled task' -ForegroundColor Cyan
$taskPath = '\KlaudikWinKitTest\'
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\cmd.exe" -Argument '/c exit 0'
Register-ScheduledTask -TaskPath $taskPath -TaskName 'Probe' -Action $action -Force | Out-Null
try {
    $t = New-Tweak 'test.task' @([pscustomobject]@{ type = 'task'; path = $taskPath; name = 'Probe'; state = 'Disabled'; defaultState = 'Enabled' })
    Invoke-WKTweak -Tweak $t | Out-Null
    Check 'task disabled' ((Get-WKTaskState -Path $taskPath -Name 'Probe') -eq 'Disabled')
    Undo-Latest 'test.task'
    Check 'task re-enabled on undo' ((Get-WKTaskState -Path $taskPath -Name 'Probe') -eq 'Enabled')
}
finally {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName 'Probe' -Confirm:$false -ErrorAction SilentlyContinue
    $svcSched = New-Object -ComObject Schedule.Service
    $svcSched.Connect()
    try { $svcSched.GetFolder('\').DeleteFolder('KlaudikWinKitTest', 0) } catch { }
}

Write-Host 'Power plan' -ForegroundColor Cyan
$original = Get-WKActivePowerScheme
$target = if ($original -eq $script:WKPowerSchemes.balanced) { 'saver' } else { 'balanced' }
$t = New-Tweak 'test.power' @([pscustomobject]@{ type = 'powerplan'; scheme = $target; defaultScheme = 'balanced' })
if ((Get-WKTweakState $t).State -eq 'Unavailable') {
    Write-Host "  skip  '$target' plan is not available on this PC" -ForegroundColor DarkGray
}
else {
    Invoke-WKTweak -Tweak $t | Out-Null
    Check "switched to $target" ((Get-WKActivePowerScheme) -eq (Resolve-WKPowerScheme $target))
    Undo-Latest 'test.power'
    Check 'original plan restored' ((Get-WKActivePowerScheme) -eq $original) "now $(Get-WKActivePowerScheme), was $original"
}
$shipped = Get-WKTweakState -Tweak (Get-WKTweak -Id 'performance.high-performance-plan')
Check 'High performance tweak is detectable' ($shipped.State -ne 'Unavailable' -or $shipped.Reason) $shipped.Reason

Write-Host 'Windows features (read only)' -ForegroundColor Cyan
foreach ($id in 'developer.wsl', 'developer.sandbox', 'developer.hyper-v') {
    $s = Get-WKTweakState -Tweak (Get-WKTweak -Id $id)
    Check "$id state: $($s.State)" ($s.State -in 'Applied', 'NotApplied', 'Partial', 'Unavailable') $s.Reason
}

if ($IncludeRealTweaks) {
    Write-Host 'Shipped tweaks (applied and undone)' -ForegroundColor Cyan
    foreach ($id in 'explorer.clock-seconds', 'privacy.telemetry-tasks') {
        $tweak = Get-WKTweak -Id $id
        $before = (Get-WKTweakState $tweak).State
        $r = Invoke-WKTweakBatch -Ids $id -Operation Apply -SkipRestorePoint
        Check "$id applied" ((Get-WKTweakState $tweak).State -eq 'Applied' -and $r.Failed -eq 0) "failed=$($r.Failed)"
        $r = Invoke-WKTweakBatch -Ids $id -Operation Undo -SkipRestorePoint
        Check "$id undone to '$before'" ((Get-WKTweakState $tweak).State -eq $before)
    }
}

if ($IncludeDns) {
    Write-Host 'DNS' -ForegroundColor Cyan
    $before = @(Get-WKDnsOverview | ForEach-Object { Format-WKDnsSetting $_.Setting }) -join ';'
    Set-WKDnsProvider -ProviderId cloudflare
    $during = @(Get-WKDnsOverview | ForEach-Object { $_.Provider }) -join ';'
    Check 'DNS switched to Cloudflare' ($during -match 'Cloudflare') $during
    Undo-Latest 'dns'
    $after = @(Get-WKDnsOverview | ForEach-Object { Format-WKDnsSetting $_.Setting }) -join ';'
    Check 'DNS restored exactly' ($after -eq $before) "$before -> $after"
}

if ($IncludeRestorePoint) {
    Write-Host 'Restore point' -ForegroundColor Cyan
    try { New-WKRestorePoint -Description 'Klaudik WinKit self-test'; Check 'restore point created' $true }
    catch { Check 'restore point created' $false $_.Exception.Message }
}

Remove-Item -LiteralPath $WK.HistoryFile -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All elevated checks passed' -ForegroundColor Green
