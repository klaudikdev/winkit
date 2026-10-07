# Klaudik WinKit launcher
#
#   irm https://klaudik.com/win | iex
#
# What this does, step by step:
#   1. Downloads WinKit {{VERSION}} from the official GitHub release.
#   2. Checks its SHA-256 against the value pinned below. If it differs by a
#      single byte, the file is deleted and nothing runs.
#   3. Asks Windows for administrator rights and starts it. The elevated
#      process hashes the file again and runs exactly the bytes it verified.
#
# Source code: https://github.com/{{REPOSITORY}}

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # AppLocker and WDAC put PowerShell in Constrained Language Mode, where
    # WinKit cannot work. Say so instead of failing with a cryptic error.
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host 'Klaudik WinKit cannot run here: PowerShell is restricted on this PC (Constrained Language Mode, set by AppLocker or WDAC).' -ForegroundColor Red
        return
    }

    $version  = '{{VERSION}}'
    $expected = '{{SHA256}}'
    $url      = "https://github.com/{{REPOSITORY}}/releases/download/v$version/WinKit.ps1"

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Host 'Klaudik WinKit runs on Windows 10 and Windows 11.' -ForegroundColor Red
        return
    }

    # Older Windows 10 setups default to TLS 1.0 in Windows PowerShell; GitHub
    # requires 1.2. Leave the OS default (which includes 1.3) alone.
    $protocols = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$protocols -ne 0 -and -not ($protocols -band [Net.SecurityProtocolType]::Tls12)) {
        [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
    }

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'KlaudikWinKit'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir "WinKit-$version.ps1"

    Write-Host ''
    Write-Host "  Klaudik WinKit $version" -ForegroundColor White
    Write-Host '  Downloading from GitHub...' -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        $bytes = [System.IO.File]::ReadAllBytes($file)
    }
    catch {
        Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $actual = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    $sha.Dispose()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Write-Host '  Checksum mismatch. The download was deleted and nothing was run.' -ForegroundColor Red
        Write-Host "  Expected $expected" -ForegroundColor DarkGray
        Write-Host "  Received $actual" -ForegroundColor DarkGray
        return
    }
    Write-Host '  Checksum verified.' -ForegroundColor Green

    # Keep in sync with New-WKVerifiedBootstrap in src/core/Elevation.ps1.
    $literal = $file.Replace("'", "''")
    $boot = @"
`$env:PSModulePath = "`$PSHOME\Modules;" + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
`$ErrorActionPreference = 'Stop'
try {
    `$bytes = [System.IO.File]::ReadAllBytes('$literal')
    `$sha = [System.Security.Cryptography.SHA256]::Create()
    `$hash = [BitConverter]::ToString(`$sha.ComputeHash(`$bytes)).Replace('-', '')
    if (`$hash -ne '$expected') { throw 'Integrity check failed: the file changed after it was verified. Nothing was run.' }
    `$text = [System.Text.Encoding]::UTF8.GetString(`$bytes).TrimStart([char]0xFEFF)
    & ([scriptblock]::Create(`$text))
}
catch {
    Write-Host "WinKit stopped: `$(`$_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($boot))

    # 64-bit Windows PowerShell, also from a 32-bit host, where System32 is
    # redirected. Built from the real Windows folder, not from %WINDIR%.
    $windows = [Environment]::GetFolderPath('Windows')
    $folder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $powershell = Join-Path $windows "$folder\WindowsPowerShell\v1.0\powershell.exe"

    Write-Host '  Starting WinKit as administrator...' -ForegroundColor DarkGray
    try {
        Start-Process -FilePath $powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Verb RunAs
    }
    catch [System.InvalidOperationException] {
        Write-Host '  WinKit was not started because administrator rights were declined.' -ForegroundColor Yellow
    }
    catch {
        Write-Host "  WinKit could not be started: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}
