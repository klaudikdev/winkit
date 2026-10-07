# Loads WinKit's non-UI code into the caller's scope for tests and tools.
#   . "$PSScriptRoot\TestHelpers.ps1"
#
# Assertions throw instead of using Should so the suite runs unchanged on
# the Pester 3.4 that ships with Windows and on Pester 5 in CI.

$script:WKRoot = Split-Path -Parent $PSScriptRoot
foreach ($folder in 'src\core', 'src\modules') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:WKRoot $folder) -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}
$script:WK = Initialize-WKContext
# Keep test output out of the user's real WinKit log.
$script:WK.LogFile = Join-Path ([System.IO.Path]::GetTempPath()) 'winkit-tests.log'

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Assertion failed')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -cne "$Actual") {
        throw ("{0}Expected '{1}' but got '{2}'." -f $(if ($Message) { "$Message. " } else { '' }), $Expected, $Actual)
    }
}

function Register-WKTestTweak {
    <# Adds a throwaway tweak to the loaded catalog, so undo treats it like a shipped one. #>
    param([Parameter(Mandatory)]$Tweak)
    $WK.Config.Tweaks.tweaks = @(@($WK.Config.Tweaks.tweaks) | Where-Object { $_.id -ne $Tweak.id }) + $Tweak
    return $Tweak
}
