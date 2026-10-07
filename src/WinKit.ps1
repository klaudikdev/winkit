<#
.SYNOPSIS
    Development entry point. Loads WinKit straight from the source tree.

.DESCRIPTION
    Release builds are a single file produced by build.ps1. This script is
    what you run while working on WinKit itself:

        powershell -ExecutionPolicy Bypass -File .\src\WinKit.ps1
        powershell -ExecutionPolicy Bypass -File .\src\WinKit.ps1 -NoElevate -Preview
#>
[CmdletBinding()]
param(
    [switch]$Preview,
    [switch]$NoElevate
)

$script:WKRoot = Split-Path -Parent $PSScriptRoot
$script:WKScriptPath = $PSCommandPath
$script:WKScriptText = $null

foreach ($folder in 'core', 'modules', 'ui', 'ui\Pages') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}

Start-WinKit @PSBoundParameters
