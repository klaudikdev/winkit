<#
.SYNOPSIS
    Verifies that every package in config/apps.json resolves to exactly one
    package in the public winget source.

.DESCRIPTION
    Run this before every release. A package can be renamed or removed from
    winget-pkgs at any time, and an unknown ID would make the install button
    fail for users.
#>
[CmdletBinding()]
param(
    # Defaults to config\apps.json in this repository.
    [string]$Catalog
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot can be empty in parameter defaults in Windows PowerShell 5.1.
if (-not $Catalog) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Catalog = Join-Path (Split-Path -Parent $here) 'config\apps.json'
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget was not found. Install "App Installer" from the Microsoft Store.'
}

$apps = (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).apps
$failed = New-Object System.Collections.Generic.List[string]

# winget writes progress to stderr; that must not abort the check.
$ErrorActionPreference = 'Continue'
foreach ($app in $apps) {
    $null = & winget show --id $app.id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ('  ok    {0}' -f $app.id) -ForegroundColor Green
    }
    else {
        Write-Host ('  FAIL  {0}  (exit 0x{1:X8})' -f $app.id, $LASTEXITCODE) -ForegroundColor Red
        $failed.Add($app.id)
    }
}

Write-Host ''
if ($failed.Count) {
    Write-Host ("{0} of {1} packages could not be resolved:" -f $failed.Count, $apps.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ("All {0} packages resolved." -f $apps.Count) -ForegroundColor Green
