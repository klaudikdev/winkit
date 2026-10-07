# Application management through winget.
#
# Packages always come from the official "winget" community source; WinKit
# never downloads installers itself.

# From winget's documented return codes (doc/windows/package-manager/winget/returnCodes.md).
$script:WKWingetCodes = @{
    '0x8A150011' = 'Package hash mismatch; the download was rejected'
    '0x8A150014' = 'Package not found in the winget source'
    '0x8A15002B' = 'No applicable update found'
    '0x8A150056' = 'This installer refuses to run as administrator; install it yourself from a normal PowerShell window with winget'
    '0x8A150061' = 'Already installed'
    '0x8A15007D' = 'Installed for another user account; manage it from that account'
    '0x8A150101' = 'The application is running; close it and try again'
    '0x8A150102' = 'Another installation is in progress; try again when it finishes'
    '0x8A150103' = 'A file the installer needs is in use; close other apps and try again'
    '0x8A150104' = 'A required dependency is missing'
    '0x8A150105' = 'Not enough disk space'
    '0x8A150106' = 'Not enough memory'
    '0x8A150107' = 'A network connection is required'
    '0x8A150108' = 'The installer reported an error; contact the app vendor'
    '0x8A150109' = 'Done, a restart is needed to finish'
    '0x8A15010A' = 'Restart Windows, then try again'
    '0x8A15010B' = 'Done, Windows will restart to finish'
    '0x8A15010C' = 'The installer was cancelled'
    '0x8A15010D' = 'Another version is already installed'
    '0x8A15010E' = 'A newer version is already installed'
    '0x8A15010F' = 'Blocked by your organization''s policy'
    '0x8A150110' = 'Dependencies could not be installed'
    '0x8A150111' = 'The application is in use by another application'
    '0x8A150113' = 'Not supported on this version of Windows'
}

# Results that leave the app installed (or nothing to do), and those that
# need a restart.
$script:WKWingetOk = '0x8A150061', '0x8A15002B', '0x8A150109', '0x8A15010B', '0x8A15010D', '0x8A15010E'
$script:WKWingetRestart = '0x8A150109', '0x8A15010B'
function Get-WKWinget {
    [CmdletBinding()]
    param()

    # The winget.exe alias lives in a folder the user can write to. Run the
    # copy inside the App Installer package instead, which only the system
    # can change.
    if ($null -eq $script:WKWingetPath) {
        $script:WKWingetPath = ''
        try {
            # Only Microsoft's signed package in the protected WindowsApps
            # folder. With Developer Mode on, anyone can register a package
            # with the same name from a folder they control.
            $apps = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps\'
            $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
            if (-not $packages.Count -and (Test-WKAdmin)) {
                # Elevated as another administrator: App Installer is registered for the signed-in user.
                $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
            }
            $package = $packages | Where-Object {
                $_.PublisherId -ceq '8wekyb3d8bbwe' -and
                "$($_.SignatureKind)" -in 'Store', 'System' -and
                -not $_.IsDevelopmentMode -and
                $_.InstallLocation -and
                ([System.IO.Path]::GetFullPath($_.InstallLocation) + '\').StartsWith($apps, [StringComparison]::OrdinalIgnoreCase)
            } | Sort-Object Version -Descending | Select-Object -First 1
            if ($package) {
                $exe = Join-Path $package.InstallLocation 'winget.exe'
                if ([System.IO.File]::Exists($exe)) { $script:WKWingetPath = $exe }
            }
        }
        catch { }
    }
    if ($script:WKWingetPath) { return $script:WKWingetPath }
    return $null
}

function Get-WKWingetStatus {
    [CmdletBinding()]
    param()

    # Native tools write to stderr for ordinary conditions; never let that throw.
    $ErrorActionPreference = 'Continue'
    $path = Get-WKWinget
    if (-not $path) {
        return [pscustomobject]@{ Available = $false; Version = $null; Message = 'winget is not installed. Get it from https://aka.ms/getwinget (or install "App Installer" from the Microsoft Store).' }
    }
    $raw = (& $path --version 2>$null | Select-Object -First 1)
    $version = $null
    if ("$raw" -match 'v?(\d+)\.(\d+)') { $version = [version]"$($Matches[1]).$($Matches[2])" }
    if (-not $version -or $version -lt [version]'1.4') {
        return [pscustomobject]@{ Available = $false; Version = "$raw"; Message = "winget $raw is too old. Update it from https://aka.ms/getwinget (or update ""App Installer"" in the Microsoft Store)." }
    }
    return [pscustomobject]@{ Available = $true; Version = "$raw".Trim(); Message = $null }
}

function Format-WKWingetExitCode {
    [CmdletBinding()]
    param([int]$Code)
    $hex = '0x{0:X8}' -f $Code
    if ($script:WKWingetCodes.ContainsKey($hex)) { return $script:WKWingetCodes[$hex] }
    return "winget exited with $hex"
}

function Get-WKInstalledPackageIds {
    <#
        Uses 'winget export', which produces JSON, instead of parsing the
        localized, column-aligned output of 'winget list'.
    #>
    [CmdletBinding()]
    param()

    $winget = Get-WKWinget
    if (-not $winget) { return @() }

    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("winkit-export-{0}.json" -f [guid]::NewGuid())
    try {
        $null = Invoke-WKProcess -FilePath $winget -ArgumentList @(
            'export', '--output', $file, '--source', 'winget',
            '--accept-source-agreements', '--disable-interactivity'
        ) -Quiet
        if (-not (Test-Path -LiteralPath $file)) { return @() }
        $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = foreach ($source in @($data.Sources)) {
            foreach ($pkg in @($source.Packages)) { $pkg.PackageIdentifier }
        }
        return @($ids | Where-Object { $_ } | Sort-Object -Unique)
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WKWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'uninstall', 'upgrade')][string]$Verb,
        [Parameter(Mandatory)][string]$Id
    )

    $winget = Get-WKWinget
    $wingetArgs = @($Verb, '--id', $Id, '--exact', '--source', 'winget', '--silent',
                    '--accept-source-agreements', '--disable-interactivity')
    if ($Verb -ne 'uninstall') { $wingetArgs += '--accept-package-agreements' }

    $r = Invoke-WKProcess -FilePath $winget -ArgumentList $wingetArgs
    $hex = '0x{0:X8}' -f $r.ExitCode
    $ok = ($r.ExitCode -eq 0) -or ($script:WKWingetOk -contains $hex)

    [pscustomobject]@{
        Id       = $Id
        Success  = $ok
        Restart  = ($script:WKWingetRestart -contains $hex)
        ExitCode = $r.ExitCode
        Message  = if ($r.ExitCode -eq 0) { 'Done' } else { Format-WKWingetExitCode $r.ExitCode }
    }
}

function Invoke-WKPackageBatch {
    <# Background entry point: installs, upgrades or removes a list of packages. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'uninstall', 'upgrade')][string]$Verb,
        [Parameter(Mandatory)][string[]]$Ids,
        [switch]$Preview
    )

    $status = Get-WKWingetStatus
    if (-not $status.Available) {
        Write-WKLog $status.Message -Level Error
        return @()
    }

    $names = @{}
    foreach ($a in @($WK.Config.Apps.apps)) { $names[$a.id] = $a.name }

    $label = @{ install = 'Installing'; uninstall = 'Removing'; upgrade = 'Updating' }[$Verb]
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($id in $Ids) {
        $i++
        $name = if ($names.ContainsKey($id)) { $names[$id] } else { $id }
        Write-WKLog "[$i/$($Ids.Count)] $label $name" -Level Step
        if ($Preview) {
            Write-WKLog "  [Preview] winget $Verb --id $id --exact --source winget"
            continue
        }
        $r = Invoke-WKWinget -Verb $Verb -Id $id
        $level = if ($r.Success) { 'Success' } else { 'Error' }
        Write-WKLog "  $name - $($r.Message)" -Level $level
        $results.Add($r)
    }

    Update-WKPathEnvironment
    $okCount = @($results | Where-Object Success).Count
    if (-not $Preview) {
        $level = if ($okCount -eq $results.Count) { 'Success' } else { 'Warning' }
        Write-WKLog "$okCount of $(Format-WKCount $results.Count 'package') finished successfully" -Level $level
    }
    return $results.ToArray()
}

function Invoke-WKUpgradeAll {
    [CmdletBinding()]
    param([switch]$Preview)

    $status = Get-WKWingetStatus
    if (-not $status.Available) { Write-WKLog $status.Message -Level Error; return }

    Write-WKLog 'Updating every app winget can update' -Level Step
    if ($Preview) { Write-WKLog '  [Preview] winget upgrade --all --silent'; return }

    $r = Invoke-WKProcess -FilePath (Get-WKWinget) -ArgumentList @(
        'upgrade', '--all', '--silent', '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity'
    )
    $hex = '0x{0:X8}' -f $r.ExitCode
    if ($r.ExitCode -eq 0 -or $hex -in '0x8A15002B', '0x8A150014') { Write-WKLog 'All updates finished' -Level Success }
    elseif ($script:WKWingetRestart -contains $hex) { Write-WKLog 'Updates finished; restart Windows to complete them' -Level Success }
    else { Write-WKLog "Some updates did not finish: $(Format-WKWingetExitCode $r.ExitCode)" -Level Warning }
    Update-WKPathEnvironment
}

function Export-WKAppSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][string]$Path
    )
    $doc = [pscustomobject]@{
        tool       = 'Klaudik WinKit'
        version    = $WK.Version
        exportedAt = (Get-Date).ToString('o')
        packages   = @($Ids)
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 4
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Import-WKAppSelection {
    <# Accepts a WinKit selection file or a 'winget export' file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids = @()
    if ($data.PSObject.Properties['packages']) { $ids = @($data.packages) }
    elseif ($data.PSObject.Properties['Sources']) {
        $ids = foreach ($s in @($data.Sources)) { foreach ($p in @($s.Packages)) { $p.PackageIdentifier } }
    }
    else { throw 'This file is not a WinKit selection or a winget export.' }

    # Only accept identifiers that look like winget IDs. Case-sensitive on
    # purpose: with a Turkish culture, case-insensitive [A-Za-z] rejects 'I'.
    return @($ids | Where-Object { $_ -is [string] -and $_ -cmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_+]{1,127}$' } | Sort-Object -Unique)
}
