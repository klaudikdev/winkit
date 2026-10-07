function New-WKRestorePoint {
    <#
        Creates a System Restore point. Windows normally allows only one per
        24 hours; the frequency limit is lifted for this call and put back
        exactly as it was afterwards.
    #>
    [CmdletBinding()]
    param([string]$Description = 'Klaudik WinKit')

    if (-not $WK.IsAdmin) { throw 'Creating a restore point requires administrator rights.' }

    $limitPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $limitName = 'SystemRestorePointCreationFrequency'
    $before = Get-WKRegistryValue -Path $limitPath -Name $limitName

    Write-WKLog 'Creating a System Restore point' -Level Step
    try {
        Set-WKRegistryValue -Path $limitPath -Name $limitName -Kind DWord -Value 0 | Out-Null
        $warnings = $null
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable warnings -WarningAction SilentlyContinue
        if ($warnings) { throw ($warnings | Select-Object -First 1).ToString() }
    }
    finally {
        if ($before.Exists) {
            Set-WKRegistryValue -Path $limitPath -Name $limitName -Kind $before.Kind -Value $before.Value | Out-Null
        }
        else {
            Remove-WKRegistryValue -Path $limitPath -Name $limitName
        }
    }

    $WK.RestorePointDone = $true
    Write-WKLog 'Restore point created' -Level Success
}

function Enable-WKSystemProtection {
    [CmdletBinding()]
    param()

    $drive = "$($env:SystemDrive)\"
    Write-WKLog "Turning on System Protection for $drive" -Level Step
    Enable-ComputerRestore -Drive $drive -ErrorAction Stop
    Write-WKLog 'System Protection is on' -Level Success
}
