<#
.SYNOPSIS
    Runs the WinKit test suite with whichever Pester version is installed
    (3.4 ships with Windows; CI uses 5.x).
#>
[CmdletBinding()]
param([string]$Path)

if (-not $Path) { $Path = Split-Path -Parent $MyInvocation.MyCommand.Path }

$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester is not installed. Run: Install-Module Pester -Scope CurrentUser' }
Import-Module $pester -Force

if ($pester.Version.Major -ge 5) {
    $config = New-PesterConfiguration
    $config.Run.Path = $Path
    $config.Run.Exit = $true
    $config.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $config
}
else {
    $result = Invoke-Pester -Script $Path -PassThru
    if ($result.FailedCount -gt 0) { exit 1 }
}
