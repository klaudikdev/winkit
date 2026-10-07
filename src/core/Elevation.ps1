function Get-WKSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-WKPowerShellPath {
    <#
        64-bit Windows PowerShell, also when called from a 32-bit host, where
        System32 is redirected to SysWOW64.
    #>
    [CmdletBinding()]
    param()
    $windows = [Environment]::GetFolderPath('Windows')
    $folder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    return (Join-Path $windows "$folder\WindowsPowerShell\v1.0\powershell.exe")
}

function New-WKVerifiedBootstrap {
    <#
        Returns a small script that re-hashes $Path and only runs it when the
        hash still matches. The bytes that are hashed are the bytes that run,
        so the file cannot be swapped between the check and the launch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256,
        [switch]$Preview
    )
    $literal = $Path.Replace("'", "''")
    # Switches must be written into the command itself; passed through a
    # variable they would arrive as a positional string.
    $switches = if ($Preview) { ' -Preview' } else { '' }
    # The first line runs before any cmdlet: modules may only come from the
    # folders that ship with Windows, not from the user's Documents folder.
    # Keep in sync with templates/launcher.ps1.
    return @"
`$env:PSModulePath = "`$PSHOME\Modules;" + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
`$ErrorActionPreference = 'Stop'
try {
    `$bytes = [System.IO.File]::ReadAllBytes('$literal')
    `$sha = [System.Security.Cryptography.SHA256]::Create()
    `$hash = [BitConverter]::ToString(`$sha.ComputeHash(`$bytes)).Replace('-', '')
    if (`$hash -ne '$Sha256') { throw 'Integrity check failed: the file changed after it was verified. Nothing was run.' }
    `$text = [System.Text.Encoding]::UTF8.GetString(`$bytes).TrimStart([char]0xFEFF)
    & ([scriptblock]::Create(`$text))$switches
}
catch {
    Write-Host "WinKit stopped: `$(`$_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
"@
}

function Start-WKElevated {
    <#
        Relaunches WinKit as administrator in 64-bit Windows PowerShell.

        Release builds relaunch the code that is already running: its text is
        written to a new, uniquely named file, hashed in memory, and the
        elevated bootstrap only runs that exact content. Nothing is re-read
        from disk to decide what is trusted. Development runs use -File.
    #>
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [string]$ScriptText,
        [switch]$Preview
    )

    $powershell = Get-WKPowerShellPath

    if ($script:WKEmbedded) {
        if (-not $ScriptText) {
            # Run through Invoke-Expression directly, WinKit cannot tell what
            # to relaunch. The launcher verifies the file and elevates it.
            Write-Host 'Start WinKit with:  irm https://klaudik.com/win | iex' -ForegroundColor Yellow
            return 'NoSource'
        }
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('KlaudikWinKit\' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'WinKit.ps1'
        $encoding = New-Object System.Text.UTF8Encoding $true
        $bytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($ScriptText))
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }

        $boot = New-WKVerifiedBootstrap -Path $path -Sha256 (Get-WKSha256 -Bytes $bytes) -Preview:$Preview
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($boot))
        $argList = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    }
    else {
        $forward = if ($Preview) { ' -Preview' } else { '' }
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"$forward"
    }

    try {
        Start-Process -FilePath $powershell -ArgumentList $argList -Verb RunAs | Out-Null
        return 'Started'
    }
    catch [System.InvalidOperationException] {
        # The user pressed "No" on the UAC prompt.
        return 'Declined'
    }
    catch {
        Write-Host "WinKit could not be started as administrator: $($_.Exception.Message)" -ForegroundColor Red
        return 'Failed'
    }
}
