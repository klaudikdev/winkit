# Developer environment: tool detection, Git identity, SSH keys and WSL.

function Get-WKDevToolStatus {
    <# Background entry point. Detects which developer tools are on PATH. #>
    [CmdletBinding()]
    param()

    Update-WKPathEnvironment
    $storeApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'

    foreach ($tool in @($WK.Config.Developer.tools)) {
        $cmd = Get-Command $tool.command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $installed = [bool]$cmd
        $path = if ($cmd) { $cmd.Source } else { $null }

        # 'python' can resolve to the Microsoft Store installer stub.
        if ($installed -and $tool.PSObject.Properties['storeAliasPackage'] -and
            $path.StartsWith("$storeApps\", [StringComparison]::OrdinalIgnoreCase)) {
            $installed = [bool](Get-ChildItem -LiteralPath $storeApps -Directory -Filter $tool.storeAliasPackage -ErrorAction SilentlyContinue)
        }

        # File versions of inbox tools (wsl.exe, ssh.exe) describe Windows, not
        # the tool, and some runtimes pad the build number; major.minor is
        # what people recognize.
        $version = $null
        $inbox = $path -and $path.StartsWith((Get-WKWindowsPath), [StringComparison]::OrdinalIgnoreCase)
        if ($installed -and -not $inbox -and $cmd.Version -and $cmd.Version -ne [version]'0.0.0.0') {
            $version = '{0}.{1}' -f $cmd.Version.Major, $cmd.Version.Minor
        }

        [pscustomobject]@{
            Name      = $tool.name
            Command   = $tool.command
            Installed = $installed
            Path      = $path
            Version   = $version
        }
    }
}

function Get-WKGitPath {
    [CmdletBinding()]
    param()
    # Only a machine-wide install is run with administrator rights.
    return (Get-WKTrustedCommand -Name 'git')
}

function Get-WKSshKeygenPath {
    [CmdletBinding()]
    param()
    $path = Get-WKSystemTool 'OpenSSH\ssh-keygen.exe'
    if ([System.IO.File]::Exists($path)) { return $path }
    return $null
}

function Get-WKGitIdentity {
    [CmdletBinding()]
    param()

    # Native tools write to stderr for ordinary conditions; never let that throw.
    $ErrorActionPreference = 'Continue'
    $git = Get-WKGitPath
    if (-not $git) { return [pscustomobject]@{ Available = $false; Name = $null; Email = $null; DefaultBranch = $null } }
    $read = { param($key) $v = & $git config --global --get $key 2>$null; if ($LASTEXITCODE -eq 0) { "$v".Trim() } else { $null } }
    [pscustomobject]@{
        Available     = $true
        Name          = & $read 'user.name'
        Email         = & $read 'user.email'
        DefaultBranch = & $read 'init.defaultBranch'
    }
}

function Test-WKSafeArgument {
    [CmdletBinding()]
    param([string]$Value)
    # Windows PowerShell mangles embedded quotes when calling native programs.
    return ($Value -notmatch '["`\r\n]')
}

function Set-WKGitIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Email,
        [string]$DefaultBranch = 'main'
    )

    $git = Get-WKGitPath
    if (-not $git) { throw 'Git is not installed. Install it from the Apps page first.' }
    if (-not $Name.Trim()) { throw 'Name cannot be empty.' }
    if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "'$Email' is not a valid email address." }
    if ($DefaultBranch -and $DefaultBranch -cnotmatch '^[A-Za-z0-9._/-]+$') { throw "'$DefaultBranch' is not a valid branch name." }
    foreach ($v in $Name, $Email) { if (-not (Test-WKSafeArgument $v)) { throw 'Quotes and line breaks are not allowed.' } }

    $settings = [ordered]@{ 'user.name' = $Name.Trim(); 'user.email' = $Email.Trim() }
    if ($DefaultBranch) { $settings['init.defaultBranch'] = $DefaultBranch }
    foreach ($key in $settings.Keys) {
        & $git config --global $key $settings[$key]
        if ($LASTEXITCODE -ne 0) { throw "git config $key failed with exit code $LASTEXITCODE." }
    }
    Write-WKLog 'Git identity saved to the global Git config' -Level Success
}

function Get-WKSshKeyPath {
    [CmdletBinding()]
    param()
    return (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
}

function Get-WKSshKeyStatus {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Continue'
    $key = Get-WKSshKeyPath
    $pub = "$key.pub"
    $sshKeygen = Get-WKSshKeygenPath
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue

    $fingerprint = $null
    if ((Test-Path -LiteralPath $pub) -and $sshKeygen) {
        $fingerprint = (& $sshKeygen -lf $pub 2>$null | Select-Object -First 1)
    }
    [pscustomobject]@{
        OpenSshAvailable = [bool]$sshKeygen
        # A lone public key still blocks generation: ssh-keygen would overwrite it.
        KeyExists        = (Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath $pub)
        PublicKeyPath    = $pub
        PublicKey        = if (Test-Path -LiteralPath $pub) { (Get-Content -LiteralPath $pub -Raw).Trim() } else { $null }
        Fingerprint      = $fingerprint
        AgentStatus      = if ($agent) { "$($agent.Status)" } else { 'NotInstalled' }
    }
}

function New-WKSshKey {
    <#
        Opens ssh-keygen in its own console window so the passphrase is typed
        by the user directly and never passes through WinKit.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Comment)

    $sshKeygen = Get-WKSshKeygenPath
    if (-not $sshKeygen) { throw 'OpenSSH Client is not installed. Add it under Settings > System > Optional features.' }
    if (-not (Test-WKSafeArgument $Comment) -or $Comment -match '\s') { throw 'The key comment must be a single word, usually your email address.' }

    $key = Get-WKSshKeyPath
    if ((Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath "$key.pub")) { throw "A key already exists at $key. WinKit never overwrites SSH keys." }
    $dir = Split-Path -Parent $key
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Write-WKLog 'Generating an Ed25519 SSH key. Enter a passphrase in the window that opens.' -Level Step
    $p = Start-Process -FilePath $sshKeygen -ArgumentList @('-t', 'ed25519', '-C', $Comment, '-f', "`"$key`"") -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $key)) { throw "ssh-keygen did not create a key (exit $($p.ExitCode))." }
    Write-WKLog "SSH key created at $key" -Level Success
}

function Get-WKWslStatus {
    <# Background entry point. #>
    [CmdletBinding()]
    param()

    # wsl.exe reports "not installed" on stderr; that is a state, not an error.
    $ErrorActionPreference = 'Continue'
    $wsl = Get-WKSystemTool 'wsl.exe'
    $distros = @()
    $ready = $false
    if (Test-Path -LiteralPath $wsl) {
        $env:WSL_UTF8 = '1'
        $out = & $wsl --list --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            # Older wsl.exe builds ignore WSL_UTF8 and print UTF-16; strip the NULs.
            $distros = @($out | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
        }
    }

    $wslTweak = Get-WKTweak -Id 'developer.wsl'
    [pscustomobject]@{
        FeatureState = (Get-WKTweakState -Tweak $wslTweak).State
        Ready        = $ready
        Distros      = $distros
    }
}

function Start-WKWslInstall {
    [CmdletBinding()]
    param([ValidateSet('Ubuntu', 'Debian', 'kali-linux', 'openSUSE-Tumbleweed')][string]$Distro = 'Ubuntu')

    $wsl = Get-WKSystemTool 'wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl)) { throw 'wsl.exe was not found. Enable WSL first and restart your PC.' }
    Write-WKLog "Installing $Distro in a new window. Follow the prompts there to create your Linux user." -Level Step
    # Through cmd with a pause, so messages such as "restart required" stay
    # readable instead of the window closing as soon as wsl finishes.
    $cmd = Get-WKSystemTool 'cmd.exe'
    Start-Process -FilePath $cmd -ArgumentList "/c `"`"$wsl`" --install -d $Distro & echo. & pause`""
}
